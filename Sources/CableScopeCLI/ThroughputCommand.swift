import CableKit
import Foundation

// MARK: - throughput 子命令：对挂载卷做读写基准，实测实际吞吐
//
// 协商速率（IOKit Speed）≠ 实际吞吐（由介质/文件系统/缓存决定）。本命令对选定卷
// 依次做"写→落盘""顺序读"两阶段基准（默认各 5 秒），区分两个口径。
//
// 用法：cablescope throughput [--volume <挂载点路径|卷名>] [--seconds N]

extension CableScopeCLI {
    static func runThroughput(volume: String?, seconds: Double) async throws {
        let candidates = ThroughputTester.listCandidateVolumes()
        let secondsText = seconds == seconds.rounded()
            ? String(format: "%.0f", seconds)
            : String(format: "%.1f", seconds)

        // 定位目标卷：指定 --volume 时按路径/卷名匹配；未指定且恰有一个外部卷则直接使用
        let target: (url: URL, name: String)
        if let volume {
            guard let match = matchVolume(volume, in: candidates) else {
                printCandidates(candidates)
                throw RuntimeError(L("未找到与「%@」匹配的卷（支持挂载点路径或卷名模糊匹配）", volume))
            }
            target = match
        } else if candidates.count == 1 {
            target = (candidates[0].url, candidates[0].name)
            print("🎯 " + L("只发现一个外部卷，自动选择：%@（%@）", target.name, target.url.path))
        } else {
            printCandidates(candidates)
            if candidates.isEmpty {
                throw RuntimeError(L("未发现可测速的外部/可移动卷（请插入 U 盘或移动硬盘后重试）"))
            }
            print(Term.dim(L("用法：%@ throughput --volume <挂载点路径|卷名>", Invocation.current)))
            throw RuntimeError(L("发现 %lld 个候选卷，请用 --volume 指定其中一个", candidates.count))
        }

        print("⏱ " + L("开始实测吞吐：%@（%@）· 每阶段 %@s", target.name, target.url.path, secondsText))
        let result: ThroughputResult
        do {
            result = try await ThroughputTester.measure(at: target.url, secondsPerPhase: seconds,
                                                        locale: CLILanguage.locale) { phase in
                switch phase {
                case .write:
                    print("📝 " + L("写入阶段…（每块落盘，测真实介质写入）"))
                case .read:
                    print("📖 " + L("读取阶段…（顺序读，测实际读取吞吐）"))
                }
                fflush(stdout)
            }
        } catch let error as ThroughputError {
            throw RuntimeError(error.description)
        }

        let writeText = result.writeMBps.map { String(format: "%.1f MB/s", $0) } ?? L("无有效数据")
        let readText = result.readMBps.map { String(format: "%.1f MB/s", $0) } ?? L("无有效数据")
        print("✅ " + L("写入 %@ · 读取 %@", writeText, readText))
        print("   " + Term.dim(L("已写入 %@ MB · 已读取 %@ MB · 总耗时 %@ 秒",
                                String(format: "%.1f", Double(result.bytesWritten) / 1_000_000),
                                String(format: "%.1f", Double(result.bytesRead) / 1_000_000),
                                String(format: "%.1f", result.elapsedSeconds))))
        print(Term.dim(L("实测吞吐 ≠ 协商速率：吞吐受介质/文件系统/缓存影响，仅供参考；协商速率请看 snapshot / rating")))
    }

    // MARK: - 卷匹配与候选展示

    /// --volume 匹配：先精确（挂载点路径/卷名，大小写不敏感），再模糊包含。
    /// internal 便于单测。
    static func matchVolume(_ query: String,
                            in candidates: [(url: URL, name: String, isRemovable: Bool)]) -> (url: URL, name: String)? {
        let key = query.lowercased()
        if let exact = candidates.first(where: { $0.url.path.lowercased() == key || $0.name.lowercased() == key }) {
            return (exact.url, exact.name)
        }
        if let fuzzy = candidates.first(where: { $0.url.path.lowercased().contains(key) || $0.name.lowercased().contains(key) }) {
            return (fuzzy.url, fuzzy.name)
        }
        return nil
    }

    private static func printCandidates(_ candidates: [(url: URL, name: String, isRemovable: Bool)]) {
        guard !candidates.isEmpty else {
            print(Term.dim(L("当前没有可测速的候选卷（可移动/外部卷）。")))
            return
        }
        print(L("候选卷："))
        for candidate in candidates {
            let tag = L(candidate.isRemovable ? "可移动" : "外部")
            print("  - \(candidate.name)  \(candidate.url.path)  [\(tag)]")
        }
    }
}
