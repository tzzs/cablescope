import Darwin
import Foundation

// MARK: - 实测吞吐（Docs/03「实测吞吐」：协商速率 ≠ 实际吞吐）
//
// 对挂载卷做固定时长的顺序写 / 顺序读基准（默认每阶段 5 秒）：
// - 写阶段：循环写随机内容块直到超时；flush 开启时每块后 synchronizeFile 强制落盘，
//   测的是真实介质写入而非页缓存（否则数值接近内存速度，严重虚高）。
// - 读阶段：从头顺序读到 EOF，未超时则反复整轮读取，按实际读取字节计速
//   （第二轮起命中页缓存，读数偏向"热读"——这正是写阶段必须落盘的原因）。
// 速率统一用十进制 MB/s 表述（1 MB = 1_000_000 字节，与磁盘厂商标称口径一致）。

/// 测速结果（Codable，便于 UI 能力卡 / 快照持久化复用）
public struct ThroughputResult: Codable, Hashable, Sendable {
    /// 卷名（取不到时回退挂载点路径末段）
    public let volumeName: String
    /// 挂载点路径
    public let mountPoint: String
    /// 写入速率（MB/s）；无法得出有效速率（耗时 ≤ 0 等）时为 nil
    public let writeMBps: Double?
    /// 读取速率（MB/s）；无法得出有效速率时为 nil
    public let readMBps: Double?
    /// 写阶段实际写出字节
    public let bytesWritten: Int64
    /// 读阶段实际读取字节（小文件反复整轮读取时可能远大于文件本身大小）
    public let bytesRead: Int64
    /// 写 + 读两阶段总耗时（秒，含建临时文件等少量准备开销）
    public let elapsedSeconds: Double

    public init(volumeName: String,
                mountPoint: String,
                writeMBps: Double?,
                readMBps: Double?,
                bytesWritten: Int64,
                bytesRead: Int64,
                elapsedSeconds: Double) {
        self.volumeName = volumeName
        self.mountPoint = mountPoint
        self.writeMBps = writeMBps
        self.readMBps = readMBps
        self.bytesWritten = bytesWritten
        self.bytesRead = bytesRead
        self.elapsedSeconds = elapsedSeconds
    }
}

/// 测速错误（只读卷 / 路径不可写 / 空间不足等）。CLI 侧转为 RuntimeError 透出（退出码 1）。
public struct ThroughputError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// ThroughputTester（Docs/02 业务层「可选实测吞吐」）：对挂载卷读写测速，区分"协商速率"与"实测值"。
public enum ThroughputTester {
    /// 测速阶段（供调用方打印进度；回调在后台线程触发）
    public enum Phase: Sendable {
        case write
        case read
    }

    // MARK: - 候选卷

    /// 卷信息查询用的 resource key（resourceValues(forKeys:) 需要 Set，显式类型避免推断失败）
    private static let volumeInfoKeys: Set<URLResourceKey> = [.volumeNameKey, .volumeIsRemovableKey, .volumeIsInternalKey]
    private static let volumeNameKeys: Set<URLResourceKey> = [.volumeNameKey]
    private static let volumeCapacityKeys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey]

    /// 列出可测速的候选卷：只保留挂在 /Volumes/ 下的可移动（U 盘/读卡器）或
    /// 外部（移动硬盘/雷雳盘/网络/镜像）卷。
    /// 注意：/System/Volumes/*（系统合成卷）与 CoreSimulator 的模拟器镜像卷
    /// 也会被 resource key 标成"外部/可移动"，必须一并排除——否则恰为唯一
    /// "候选"时会被自动选中，把测速文件写进系统数据卷。
    public static func listCandidateVolumes() -> [(url: URL, name: String, isRemovable: Bool)] {
        let mounted = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(volumeInfoKeys),
            options: [.skipHiddenVolumes]
        ) ?? []
        var candidates: [(url: URL, name: String, isRemovable: Bool)] = []
        for url in mounted {
            // 用户可见的挂载卷统一挂在 /Volumes/ 下；根系统卷（"/"）与其他
            // 非常规挂载点（/System/Volumes/*、模拟器镜像等）在此一并挡掉。
            guard url.path.hasPrefix("/Volumes/") else { continue }
            let values = try? url.resourceValues(forKeys: volumeInfoKeys)
            let isInternal = values?.volumeIsInternal ?? false
            let isRemovable = values?.volumeIsRemovable ?? false
            let name = values?.volumeName ?? url.lastPathComponent
            // 再排除内置盘（如 /Volumes/Macintosh HD - Data），避免误测内置盘
            guard isRemovable || !isInternal else { continue }
            candidates.append((url: url, name: name, isRemovable: isRemovable))
        }
        return candidates
    }

    // MARK: - 测速入口

    /// 对 `volumeURL` 做写/读两阶段基准，每阶段 `secondsPerPhase` 秒。
    /// - Parameters:
    ///   - chunkBytes: 单次读写块大小（默认 4 MiB）。
    ///   - flush: 写阶段每块后 `synchronizeFile` 强制落盘。开启时测真实介质吞吐；
    ///     关闭时写入大多停留在页缓存，数值虚高（仅适合对比缓存效应）。
    ///   - onPhaseChange: 阶段切换回调（后台线程触发，供 CLI/UI 打进度）。
    /// 阻塞 I/O 全程在 Task.detached 中执行，不占用协作线程池（对齐 CableKit 其他 Service）。
    public static func measure(at volumeURL: URL,
                               secondsPerPhase: TimeInterval = 5,
                               chunkBytes: Int = 4 * 1024 * 1024,
                               flush: Bool = true,
                               onPhaseChange: (@Sendable (Phase) -> Void)? = nil) async throws -> ThroughputResult {
        try await Task.detached(priority: .utility) {
            try Self.runMeasurement(at: volumeURL,
                                    secondsPerPhase: secondsPerPhase,
                                    chunkBytes: chunkBytes,
                                    flush: flush,
                                    onPhaseChange: onPhaseChange)
        }.value
    }

    // MARK: - 同步测速核心（阻塞 I/O，仅由 detached 上下文调用）

    private static func runMeasurement(at volumeURL: URL,
                                       secondsPerPhase: TimeInterval,
                                       chunkBytes: Int,
                                       flush: Bool,
                                       onPhaseChange: (@Sendable (Phase) -> Void)?) throws -> ThroughputResult {
        guard secondsPerPhase > 0 else {
            throw ThroughputError("每阶段时长必须大于 0 秒（当前 \(secondsPerPhase)）")
        }
        guard chunkBytes > 0 else {
            throw ThroughputError("读写块大小必须大于 0 字节（当前 \(chunkBytes)）")
        }

        // 空间预检：至少容纳 2 个块（写入文件 + 文件系统元数据余量）。
        // 取不到容量信息（非卷路径等）时跳过该检查，交给写阶段自然报错。
        if let capacity = try? volumeURL.resourceValues(forKeys: volumeCapacityKeys),
           let available = capacity.volumeAvailableCapacityForImportantUsage,
           available < Int64(chunkBytes) * 2 {
            throw ThroughputError("空间不足：目标卷可用 \(available) 字节，测速至少需要 \(Int64(chunkBytes) * 2) 字节")
        }

        let clock = ContinuousClock()
        let totalStart = clock.now

        // 临时测速文件建在卷根下，UUID 保证并发/重复运行不冲突
        let fileURL = volumeURL.appendingPathComponent(".cablescope-throughput-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
            throw ThroughputError("无法在「\(volumeURL.path)」创建临时测速文件（卷可能为只读、路径不可写或不存在）")
        }
        // O_RDWR 打开（forUpdating）：写阶段写入、读阶段用同一句柄回读——
        // forWritingTo 是 O_WRONLY 只写句柄，读阶段会直接 EBADF。
        guard let handle = try? FileHandle(forUpdating: fileURL) else {
            try? FileManager.default.removeItem(at: fileURL)
            throw ThroughputError("无法打开临时测速文件用于读写：\(fileURL.path)")
        }
        // finally 必删：无论正常结束、抛错还是取消，临时文件都不能残留在用户卷上
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: fileURL)
        }

        // 随机内容填充一次、全程复用：避免可压缩/可去重的内容让介质"虚高"，
        // 同时不在循环内反复生成随机数引入额外开销。
        let chunk = randomChunk(byteCount: chunkBytes)

        // ---------- 写阶段：循环写直到超时（至少写一块，保证读阶段有内容可读） ----------
        onPhaseChange?(.write)
        let writeDeadline = clock.now.advanced(by: .seconds(secondsPerPhase))
        let writeStart = clock.now
        var bytesWritten: Int64 = 0
        repeat {
            do {
                try handle.write(contentsOf: chunk)
                // flush：每块后强制落盘。没有这一步，写入大多停在页缓存里，
                // 测出来的是内存速度而不是 U 盘/SSD 的真实介质吞吐。
                if flush { handle.synchronizeFile() }
            } catch {
                // 卷写满（ENOSPC）是有界基准在小卷/接近满的卷上的正常终止方式：
                // 已落盘的字节依然有效，按实际量计速，不让整个测速失败。
                guard Self.isOutOfSpace(error) else { throw ThroughputError("写入失败：\(error)") }
                break
            }
            bytesWritten += Int64(chunk.count)
        } while clock.now < writeDeadline && !Task.isCancelled
        let writeElapsed = durationSeconds(writeStart.duration(to: clock.now))

        // ---------- 读阶段：从头顺序读到 EOF，未超时就再来一轮；超时截断按实际读取量计 ----------
        onPhaseChange?(.read)
        let readDeadline = clock.now.advanced(by: .seconds(secondsPerPhase))
        let readStart = clock.now
        var bytesRead: Int64 = 0
        do {
            // 注意：第二轮起会命中页缓存，读数偏向"热读"；冷读吞吐以第一轮为准。
            while clock.now < readDeadline && !Task.isCancelled {
                handle.seek(toFileOffset: 0)
                while clock.now < readDeadline && !Task.isCancelled {
                    guard let data = try handle.read(upToCount: chunkBytes), !data.isEmpty else {
                        break // EOF → 下一轮从头再读
                    }
                    bytesRead += Int64(data.count)
                }
            }
        } catch {
            throw ThroughputError("读取失败：\(error)")
        }
        let readElapsed = durationSeconds(readStart.duration(to: clock.now))

        let volumeName = (try? volumeURL.resourceValues(forKeys: volumeNameKeys))?.volumeName
            ?? volumeURL.lastPathComponent
        return ThroughputResult(
            volumeName: volumeName,
            mountPoint: volumeURL.path,
            writeMBps: computeMBps(bytes: bytesWritten, elapsed: writeElapsed),
            readMBps: computeMBps(bytes: bytesRead, elapsed: readElapsed),
            bytesWritten: bytesWritten,
            bytesRead: bytesRead,
            elapsedSeconds: durationSeconds(totalStart.duration(to: clock.now))
        )
    }

    // MARK: - 纯计算（internal 便于单测）

    /// 字节 / 耗时 → MB/s（十进制，1 MB = 1_000_000 字节，与磁盘标称口径一致）。
    /// 耗时 ≤ 0 或字节 < 0 视为无有效测量，返回 nil；字节 = 0 是合法测量（速率为 0）。
    static func computeMBps(bytes: Int64, elapsed: TimeInterval) -> Double? {
        guard elapsed > 0, bytes >= 0 else { return nil }
        return Double(bytes) / 1_000_000 / elapsed
    }

    // MARK: - 私有辅助

    /// 是否"卷空间不足"（NSFileHandle 抛 Cocoa 640 或底层 POSIX ENOSPC）
    private static func isOutOfSpace(_ error: Error) -> Bool {
        let nsError = error as NSError
        return (nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteOutOfSpaceError)
            || (nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOSPC))
    }

    /// 随机填充一次的写入块
    private static func randomChunk(byteCount: Int) -> Data {
        var data = Data(count: byteCount)
        data.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            arc4random_buf(base, buffer.count)
        }
        return data
    }

    /// Duration → 秒（Double）
    private static func durationSeconds(_ duration: Duration) -> TimeInterval {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) + Double(attoseconds) / 1_000_000_000_000_000_000
    }
}
