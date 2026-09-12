import Foundation

/// 快照监视器：并发组合四个 Service，容错聚合为 `CableSnapshot`，并提供变化检测事件流。
///
/// 并发模型：
/// - `snapshotNow()` 用 `async let` 并发拉取四个 Service；**单个 Service 失败只降级为
///   空数组/nil，不让整体失败**（协议契约：整机快照不因个别维度异常而抛错）。
/// - `snapshotStream()`：实现说明——`IOServiceAddMatchingNotification` 需要在专用 dispatch
///   queue 上驱动并手动管理 IOObjectRelease/IOService 生命周期，桥接成本高且易泄漏；
///   本实现采用任务允许的替代方案：**1.5s 间隔轮询 + 内容变化检测**（对比除 id/timestamp
///   之外的内容签名，仅在变化时 yield）。保证：Task.sleep 不忙等；`onTermination` 取消
///   轮询任务；无额外线程/句柄驻留，无内存泄漏。
public final class CableMonitor: CableMonitorProtocol {
    private let usb: USBServiceProtocol
    private let power: PowerServiceProtocol
    private let display: DisplayServiceProtocol
    private let thunderbolt: ThunderboltServiceProtocol

    /// 轮询间隔（秒）。
    private let pollInterval: TimeInterval

    public init(usb: USBServiceProtocol = USBService(),
                power: PowerServiceProtocol = PowerService(),
                display: DisplayServiceProtocol = DisplayService(),
                thunderbolt: ThunderboltServiceProtocol = ThunderboltService(),
                pollInterval: TimeInterval = 1.5) {
        self.usb = usb
        self.power = power
        self.display = display
        self.thunderbolt = thunderbolt
        self.pollInterval = pollInterval
    }

    // MARK: - CableMonitorProtocol

    public func snapshotNow() async throws -> CableSnapshot {
        async let usbDevices = usb.listUSBDevices()
        async let powerSnapshot = power.currentPower()
        async let displays = display.listDisplays()
        async let thunderboltDevices = thunderbolt.listThunderboltDevices()

        return CableSnapshot(
            usbDevices: (try? await usbDevices) ?? [],
            power: (try? await powerSnapshot) ?? nil,
            displays: (try? await displays) ?? [],
            thunderboltDevices: (try? await thunderboltDevices) ?? []
        )
    }

    public func snapshotStream() -> AsyncStream<CableSnapshot> {
        AsyncStream { continuation in
            let task = Task(priority: .utility) { [pollInterval] in
                // 内容签名：排除 id/timestamp（每次快照必然不同），只比较真实载荷。
                var lastKey: ContentKey?
                while !Task.isCancelled {
                    if let snapshot = try? await self.snapshotNow() {
                        let key = ContentKey(snapshot: snapshot)
                        if key != lastKey {
                            lastKey = key
                            continuation.yield(snapshot)
                        }
                    }
                    do {
                        try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
                    } catch {
                        break // 取消/超时：退出轮询，不再产出
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// 快照内容签名（不含 id/timestamp）。
    private struct ContentKey: Hashable {
        let usbDevices: [USBDeviceSnapshot]
        let power: PowerSnapshot?
        let displays: [DisplaySnapshot]
        let thunderboltDevices: [ThunderboltDeviceSnapshot]

        init(snapshot: CableSnapshot) {
            self.usbDevices = snapshot.usbDevices
            self.power = snapshot.power
            self.displays = snapshot.displays
            self.thunderboltDevices = snapshot.thunderboltDevices
        }
    }
}
