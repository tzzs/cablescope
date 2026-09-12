import CableKit
import Darwin
import Dispatch
import Foundation

// MARK: - watch 子命令：持续监听状态变化，变化时打印一行摘要（Ctrl-C 优雅退出）

extension CableScopeCLI {
    static func runWatch(interval: TimeInterval) async {
        let monitor = CableMonitor()
        let intervalText = interval == interval.rounded()
            ? String(format: "%.0f", interval)
            : String(format: "%.1f", interval)
        print("👀 CableScope watch · 事件流 + 兜底轮询 \(intervalText)s · Ctrl-C 退出")
        fflush(stdout)

        // Ctrl-C / SIGTERM → 取消监听 Task，走优雅退出
        let box = SignalTaskBox()
        SignalHandlers.install { box.task?.cancel() }

        let task = Task { () -> Void in
            var last: CableSnapshot?
            let events = monitor.snapshotStream()

            // 双来源汇合：监视器事件流（插拔/电源通知）+ CLI 侧按 interval 兜底轮询。
            // 两条路径的快照都会经同一个 diff 去重，内容无变化时不产生输出。
            let merged = AsyncStream<CableSnapshot> { continuation in
                let relay = Task {
                    for await snapshot in events { continuation.yield(snapshot) }
                }
                let poller = Task {
                    while !Task.isCancelled {
                        do { try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000)) }
                        catch { break }
                        if let snapshot = try? await monitor.snapshotNow() {
                            continuation.yield(snapshot)
                        }
                    }
                }
                continuation.onTermination = { _ in
                    relay.cancel()
                    poller.cancel()
                }
            }

            for await snapshot in merged {
                if Task.isCancelled { break }
                if let previous = last {
                    let changes = SnapshotDiff.changes(from: previous, to: snapshot)
                    if !changes.isEmpty {
                        print("[\(Fmt.clock(snapshot.timestamp))]  " + changes.joined(separator: "；"))
                        fflush(stdout)
                    }
                } else {
                    print("📍 基线快照  " + SnapshotDiff.baselineSummary(snapshot))
                    fflush(stdout)
                }
                last = snapshot
            }
        }
        box.task = task
        await task.value

        print("\n👋 监听已退出")
    }
}

// MARK: - 信号处理

private enum SignalHandlers {
    /// 持有 source 防止释放；进程生命周期内常驻
    static var sources: [DispatchSourceSignal] = []

    static func install(onCancel: @escaping @Sendable () -> Void) {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        for signo in [SIGINT, SIGTERM] {
            let source = DispatchSource.makeSignalSource(signal: signo, queue: DispatchQueue.global())
            source.setEventHandler(handler: onCancel)
            source.resume()
            sources.append(source)
        }
    }
}

private final class SignalTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var underlying: Task<Void, Never>?

    var task: Task<Void, Never>? {
        get { lock.withLock { underlying } }
        set { lock.withLock { underlying = newValue } }
    }
}

// MARK: - 快照差异

/// 快照差异计算（internal 便于单测；纯函数，无 IO 依赖）
enum SnapshotDiff {
    /// 两次快照之间的变化点；无变化返回空数组
    static func changes(from old: CableSnapshot, to new: CableSnapshot) -> [String] {
        var out: [String] = []

        diffPower(old: old.power, new: new.power, into: &out)
        diffUSB(old: old.usbDevices, new: new.usbDevices, into: &out)
        diffDisplays(old: old.displays, new: new.displays, into: &out)
        diffThunderbolt(old: old.thunderboltDevices, new: new.thunderboltDevices, into: &out)

        return out
    }

    static func baselineSummary(_ snapshot: CableSnapshot) -> String {
        var parts: [String] = []
        parts.append("⚡ " + (snapshot.power?.shortSummary ?? "暂无数据"))
        parts.append("USB ×\(snapshot.usbDevices.count)")
        parts.append("显示器 ×\(snapshot.displays.count)")
        parts.append("雷电 ×\(snapshot.thunderboltDevices.count)")
        return parts.joined(separator: " · ")
    }

    private static func diffPower(old: PowerSnapshot?, new: PowerSnapshot?, into out: inout [String]) {
        switch (old, new) {
        case (nil, let newPower?):
            out.append("电源信息可用：" + newPower.shortSummary)
        case (let oldPower?, nil):
            out.append("电源信息不可用（原：\(oldPower.shortSummary)）")
        case (let oldPower?, let newPower?):
            if oldPower.isCharging != newPower.isCharging {
                out.append(newPower.isCharging ? "开始充电" : "已停止充电")
            }
            // 功率变化超过 1 W 才报告
            switch (oldPower.watts, newPower.watts) {
            case (nil, let watts?):
                out.append("功率开始上报 \(Fmt.watts(watts))")
            case (.some, nil):
                out.append("功率不再上报")
            case (let before?, let after?) where abs(after - before) > 1.0:
                out.append(String(format: "功率 %.1f W → %.1f W", before, after))
            default:
                break
            }
            if let before = oldPower.pdContract, let after = newPower.pdContract, before != after {
                out.append("PD 合同 \(contractText(before)) → \(contractText(after))")
            }
            if let before = oldPower.batteryPercent, let after = newPower.batteryPercent {
                let beforeInt = Int(before.rounded())
                let afterInt = Int(after.rounded())
                if beforeInt != afterInt {
                    out.append("电量 \(beforeInt)% → \(afterInt)%")
                }
            }
        default:
            break
        }
    }

    private static func diffUSB(old: [USBDeviceSnapshot], new: [USBDeviceSnapshot], into out: inout [String]) {
        // 跨快照按 LocationID（物理端口）配对
        let oldByLocation = Dictionary(old.map { ($0.locationID, $0) }, uniquingKeysWith: { first, _ in first })
        let newByLocation = Dictionary(new.map { ($0.locationID, $0) }, uniquingKeysWith: { first, _ in first })

        for (_, device) in newByLocation where oldByLocation[device.locationID] == nil {
            out.append("USB 接入：\(device.displayName) · \(device.speedDescription)")
        }
        for (_, device) in oldByLocation where newByLocation[device.locationID] == nil {
            out.append("USB 断开：\(device.displayName)")
        }
        for (_, newDevice) in newByLocation {
            guard let oldDevice = oldByLocation[newDevice.locationID] else { continue }
            if oldDevice.productName != newDevice.productName {
                out.append("USB 设备变更：\(oldDevice.displayName) → \(newDevice.displayName)")
            }
            if let before = oldDevice.speed?.bitsPerSecond, let after = newDevice.speed?.bitsPerSecond, before != after {
                out.append("USB 速率 \(USBSpeed(bitsPerSecond: before).label) → \(USBSpeed(bitsPerSecond: after).label)")
            } else if oldDevice.speed == nil, let after = newDevice.speed?.bitsPerSecond {
                out.append("USB 速率未知 → \(USBSpeed(bitsPerSecond: after).label)")
            }
        }
    }

    private static func diffDisplays(old: [DisplaySnapshot], new: [DisplaySnapshot], into out: inout [String]) {
        let oldByID = Dictionary(old.map { ($0.displayID, $0) }, uniquingKeysWith: { first, _ in first })
        let newByID = Dictionary(new.map { ($0.displayID, $0) }, uniquingKeysWith: { first, _ in first })

        for (_, display) in newByID where oldByID[display.displayID] == nil {
            out.append("显示器接入：\(display.displayName) \(display.resolutionLabel)")
        }
        for (_, display) in oldByID where newByID[display.displayID] == nil {
            out.append("显示器断开：\(display.displayName) \(display.resolutionLabel)")
        }
        for (_, newDisplay) in newByID {
            guard let oldDisplay = oldByID[newDisplay.displayID] else { continue }
            if oldDisplay.pixelWidth != newDisplay.pixelWidth || oldDisplay.pixelHeight != newDisplay.pixelHeight {
                out.append("分辨率 \(oldDisplay.resolutionLabel) → \(newDisplay.resolutionLabel)")
            }
            if let before = oldDisplay.refreshRateHz, let after = newDisplay.refreshRateHz, before != after {
                out.append(String(format: "刷新率 %.0f Hz → %.0f Hz", before, after))
            }
            if oldDisplay.linkRateLabel != newDisplay.linkRateLabel {
                out.append("DP 链路 \(oldDisplay.linkRateLabel ?? "未知") → \(newDisplay.linkRateLabel ?? "未知")")
            }
            if oldDisplay.isMain != newDisplay.isMain {
                out.append(newDisplay.isMain ? "主显示器切换" : "主显示器身份变化")
            }
        }
    }

    private static func diffThunderbolt(old: [ThunderboltDeviceSnapshot], new: [ThunderboltDeviceSnapshot], into out: inout [String]) {
        let oldIDs = Set(old.map(\.id))
        let newIDs = Set(new.map(\.id))
        if oldIDs == newIDs { return }
        let added = new.filter { !oldIDs.contains($0.id) }.map(\.name)
        let removed = old.filter { !newIDs.contains($0.id) }.map(\.name)
        if !added.isEmpty { out.append("雷电接入：" + added.joined(separator: "、")) }
        if !removed.isEmpty { out.append("雷电断开：" + removed.joined(separator: "、")) }
    }

    private static func contractText(_ contract: PDContract) -> String {
        "\(Fmt.volts(contract.voltageMV)) × \(Fmt.amps(contract.currentMA))"
    }
}
