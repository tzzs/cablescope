import Dispatch
import Foundation
import IOKit

/// 快照监视器：并发组合六个 Service，容错聚合为 `CableSnapshot`，并提供变化检测事件流。
///
/// 并发模型（混合模式：**IOKit 事件通知驱动 + pollInterval 兜底轮询**）：
/// - `snapshotNow()` 用 `async let` 并发拉取六个 Service；**单个 Service 失败只降级为
///   空数组/nil，不让整体失败**（协议契约：整机快照不因个别维度异常而抛错）。
/// - `snapshotStream()` 的等待逻辑：每轮采集后等待"事件信号 OR pollInterval 超时"，
///   先到者胜、两者都会触发下一轮采集。事件源三类，任一触发都只是"该重新采集了"，
///   共同汇入同一个 `DispatchSemaphore`：
///   ① `AppleSmartBattery` 兴趣通知（电源插拔/充放电变化近零延迟）；
///   ② USB 设备 **publish** 匹配通知：`IOServiceAddMatchingNotification` +
///      `kIOPublishNotification` 匹配 `IOUSBHostDevice`——服务注册（设备接入）即触发；
///   ③ USB 设备 **terminate** 匹配通知：同一 API + `kIOTerminatedNotification`——服务
///      终止（设备断开）即触发。类型组合选择：publish/terminate 恰好覆盖"插"与"拔"
///      两态；`kIOMatchedNotification` 会随驱动匹配状态变化多发（无害但多余），
///      `kIOFirstPublishNotification` 对每次物理插拔都生成新 IOService 实例的场景与
///      publish 等价、无额外收益（SDK IOKitLib.h 对各类型的语义定义见其注释），故不选。
///   pollInterval 兜底覆盖三类通知都不覆盖的变化（如显示器/雷雳拓扑），语义与旧纯
///   轮询一致（默认 1.5s）。
///   - 通知搭建：`IONotificationPortCreate(kIOMainPortDefault)` + `IONotificationPortSetDispatchQueue`
///     （电池桥与 USB 桥各自专用串行 queue，回调不占协作线程池）。电池桥另需
///     `IOServiceGetMatchingService("AppleSmartBattery")`（返回 +1 引用，retain 保持存活）
///     + `IOServiceAddInterestNotification(kIOGeneralInterest)`。
///   - 匹配通知的关键语义（与兴趣通知的最大差异）：注册成功后 **iterator 里预装了当前
///     已存在的全部匹配项**，必须先排干（`IOIteratorNext` 到 0，逐项 `IOObjectRelease`）
///     通知才算 armed，否则 handler 永不触发；此后每次设备发布/终止，内核把新匹配项
///     装载进 iterator 并触发 handler，handler 里同样排干（terminate 项的排干同时放行
///     "待终止"设备对象——不被通知再引用的设备才真正销毁）。排干只发生在通知 queue
///     （回调线程）：事件排干在 C 回调内完成，初始排干经 `queue.sync` 派发到同一 queue
///     ——**iterator 从不进入 Swift 异步上下文，主等待循环只消费信号量**。
///   - 句柄与所有权：匹配通知的 out param **就是 iterator 本身**（无独立 notification
///     句柄），释放 iterator 即注销通知；`IOServiceMatching` 字典一经传入
///     `IOServiceAddMatchingNotification` 即被消费（头文件标注 `CF_RELEASES_ARGUMENT`，
///     成功与否都归 API 所有），调用方不得再释放，publish/terminate 两次注册各建一份。
///   - 信号原语用 `DispatchSemaphore` 而非旧设想中的 `AsyncStream<Void>` + `withTaskGroup`
///     竞速（信号 `next()` vs `Task.sleep`）：实测取消挂在 `next()` 上的任务会**永久终止整个
///     AsyncStream**（onTermination 触发、后续 `next()` 恒 nil）——竞速落败方必须 cancel，
///     于是信号源在第一次超时就死了。信号量自带超时等待，"放弃等待"不损伤信号源，且可经
///     `Unmanaged` 作 refcon 直传 C 回调，桥接最简。
///   - 生命周期（当年注释担心的"易泄漏"如何解决）：两个事件桥（电池、USB）各自拥有通知
///     端口、专用 queue、句柄、refcon 桥，随每次 `snapshotStream()` 的采集任务建立，清理
///     收口在任务作用域 `defer`（LIFO、恰好一次）。电池桥逆序：
///     `IOObjectRelease(notification)`（注销内核侧兴趣通知，此后不再投递）→
///     `IOObjectRelease(service)`（平衡 GetMatchingService 的 retain）→
///     `IONotificationPortDestroy(port)`（销毁 mach port 并解除与专用 queue 的挂接，此后
///     不可能再有回调）→ 释放 refcon（平衡 `Unmanaged.passRetained(semaphore)`，信号量
///     存活期与注册期严格一致）。USB 桥逆序：`IOObjectRelease(publish iterator)` →
///     `IOObjectRelease(terminate iterator)`（释放即注销）→ `IONotificationPortDestroy(port)`
///     → 释放 refcon。注册任一步失败就地清理全部半成品并退化为"永不触发的信号量"，
///     等待总是走满超时——**静默退回纯轮询，行为与旧实现完全一致**。
///     无跨流共享状态、无句柄驻留、无内存泄漏。
///   - 不变式保持：首个快照立即产出；内容签名（排除 id/timestamp）去重、仅变化才 yield；
///     取消即终止（onTermination → Task.cancel；取消经 onCancel 即时唤醒等待中的信号量；
///     另有 yield 返回 `.terminated` 的双保险）；同步等待在 detached utility 线程上阻塞
///     （≤ pollInterval），不占 Swift 协作线程池。
public final class CableMonitor: CableMonitorProtocol {
    private let usb: USBServiceProtocol
    private let power: PowerServiceProtocol
    private let display: DisplayServiceProtocol
    private let thunderbolt: ThunderboltServiceProtocol
    private let ports: PortControllerServiceProtocol
    private let displayPortTransport: DisplayPortTransportServiceProtocol

    /// 兜底轮询间隔（秒）。电源与 USB 插拔分别由 AppleSmartBattery 兴趣通知、IOUSBHostDevice
    /// publish/terminate 匹配通知即时驱动，不受此间隔限制；三类通知都不覆盖的变化（显示器、
    /// 雷雳拓扑等）仍按此间隔兜底发现——语义与旧纯轮询一致。
    private let pollInterval: TimeInterval

    public init(usb: USBServiceProtocol = USBService(),
                power: PowerServiceProtocol = PowerService(),
                display: DisplayServiceProtocol = DisplayService(),
                thunderbolt: ThunderboltServiceProtocol = ThunderboltService(),
                ports: PortControllerServiceProtocol = PortControllerService(),
                displayPortTransport: DisplayPortTransportServiceProtocol = DisplayPortTransportService(),
                pollInterval: TimeInterval = 1.5) {
        self.usb = usb
        self.power = power
        self.display = display
        self.thunderbolt = thunderbolt
        self.ports = ports
        self.displayPortTransport = displayPortTransport
        self.pollInterval = pollInterval
    }

    // MARK: - CableMonitorProtocol

    public func snapshotNow() async throws -> CableSnapshot {
        async let usbDevices = usb.listUSBDevices()
        async let powerSnapshot = power.currentPower()
        async let displays = display.listDisplays()
        async let thunderboltDevices = thunderbolt.listThunderboltDevices()
        async let portSnapshots = ports.listPorts()
        async let displayPortLinkSnapshots = displayPortTransport.listDisplayPortLinks()

        let usb = (try? await usbDevices) ?? []
        let thunderbolt = (try? await thunderboltDevices) ?? []
        let ports = (try? await portSnapshots) ?? []

        return CableSnapshot(
            usbDevices: usb,
            power: (try? await powerSnapshot) ?? nil,
            displays: (try? await displays) ?? [],
            thunderboltDevices: thunderbolt,
            sessions: PortGrouping.buildSessions(usbDevices: usb, thunderboltDevices: thunderbolt, ports: ports),
            ports: ports,
            displayPortLinks: (try? await displayPortLinkSnapshots) ?? []
        )
    }

    public func snapshotStream() -> AsyncStream<CableSnapshot> {
        AsyncStream { continuation in
            let task = Task(priority: .utility) { [pollInterval] in
                // 共享事件信号量：三类事件源（电池兴趣 / USB publish / USB terminate）任一触发
                // 都只是"该重新采集了"，不区分来源（变化内容由下一轮快照 diff 自然呈现）。
                let eventSignal = DispatchSemaphore(value: 0)

                // 电源事件信号源：AppleSmartBattery 兴趣通知桥。注册失败时返回空 teardown、
                // 信号永不触发（等待总走满超时 = 静默退回纯轮询）；teardown 随本任务作用域
                // 逆序清理、恰好一次。
                let batteryTeardown = Self.makeBatteryEventSignal(signal: eventSignal)
                defer { batteryTeardown() }

                // USB 事件信号源：IOUSBHostDevice publish/terminate 匹配通知桥（失败同样静默退化）。
                let usbTeardown = Self.makeUSBEventSignal(signal: eventSignal)
                defer { usbTeardown() }

                // 内容签名：排除 id/timestamp（每次快照必然不同），只比较真实载荷。
                var lastKey: ContentKey?
                while !Task.isCancelled {
                    if let snapshot = try? await self.snapshotNow() {
                        let key = ContentKey(snapshot: snapshot)
                        if key != lastKey {
                            lastKey = key
                            // .terminated = 消费侧已取消/丢弃流：立即收尾（不依赖 onTermination 时序的双保险）。
                            if case .terminated = continuation.yield(snapshot) { break }
                        }
                    }
                    // 等待事件信号 OR 超时：信号到达 → 立即采集（电源/USB 变化近零延迟）；
                    // 超时到达 → 兜底采集（三类通知都不覆盖的变化仍被发现）。
                    await Self.waitForEventOrTimeout(eventSignal, timeout: pollInterval)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - AppleSmartBattery 兴趣通知桥（私有实现细节）

    /// 搭建 AppleSmartBattery 兴趣通知 → `DispatchSemaphore` 桥；信号汇入调用方提供的
    /// `signal`（与 USB 匹配通知桥共用同一信号量）。
    ///
    /// - Returns: teardown 闭包。注册成功时 C 回调会对 signal `signal()`；任一步失败时
    ///   所有半成品资源已就地清理，返回空 teardown（信号永不触发 = 纯轮询退回）。
    ///   teardown 必须恰好调用一次（调用方用 defer 保证），逆序释放全部 IOKit 对象。
    private static func makeBatteryEventSignal(signal: DispatchSemaphore) -> @Sendable () -> Void {
        // 1) 通知端口 + 专用串行 queue：IOKit mach 消息在此 queue 上驱动 C 回调。
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            return {}
        }
        let queue = DispatchQueue(label: "CableKit.CableMonitor.AppleSmartBatteryInterest", qos: .utility)
        IONotificationPortSetDispatchQueue(port, queue)

        // 2) 服务句柄：IOServiceGetMatchingService 返回 +1 引用，须保持到注销为止（teardown 释放）。
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else {
            IONotificationPortDestroy(port)
            return {}
        }

        // 3) 兴趣通知：kIOGeneralInterest（电源插拔/充放电等 messageClients 状态变化都会触发）。
        //    C 函数指针不能捕获上下文——refcon 用 Unmanaged.passRetained 携带信号量，
        //    使信号量存活期与注册期严格一致（teardown 最后一步才平衡 release）。
        let refcon = Unmanaged.passRetained(signal).toOpaque()
        var notification = io_object_t(0)
        let kr = IOServiceAddInterestNotification(port, service, kIOGeneralInterest, { refcon, _, _, _ in
            guard let refcon else { return }
            Unmanaged<DispatchSemaphore>.fromOpaque(refcon).takeUnretainedValue().signal()
        }, refcon, &notification)

        guard kr == KERN_SUCCESS else {
            Unmanaged<DispatchSemaphore>.fromOpaque(refcon).release() // 平衡 passRetained
            IOObjectRelease(service)
            IONotificationPortDestroy(port)
            return {}
        }

        let registeredNotification = notification
        // port/refcon 是 IOKit C 指针类型（OpaquePointer / UnsafeMutableRawPointer），
        // 本身不是 Sendable；装箱后交给 teardown 闭包捕获，消除严格并发检查告警——
        // 见 IOKitPointerBox 的 @unchecked Sendable 说明。
        let portBox = IOKitPointerBox(pointer: port)
        let refconBox = IOKitPointerBox(pointer: refcon)
        return {
            IOObjectRelease(registeredNotification)                            // a) 注销内核侧兴趣通知
            IOObjectRelease(service)                                           // b) 释放服务句柄（平衡步骤 2 的 retain）
            IONotificationPortDestroy(portBox.pointer)                         // c) 销毁端口并解除 queue 挂接（此后不可能再有回调）
            Unmanaged<DispatchSemaphore>.fromOpaque(refconBox.pointer).release() // d) 最后平衡 passRetained
        }
    }

    // MARK: - IOUSBHostDevice 匹配通知桥（私有实现细节）

    /// 搭建 IOUSBHostDevice publish/terminate 匹配通知 → `DispatchSemaphore` 桥；USB 接入/
    /// 断开事件信号汇入调用方提供的 `signal`（与电池兴趣通知桥共用）。
    ///
    /// 匹配通知语义（与兴趣通知的关键差异，详见类型注释）：
    /// - out param **就是 iterator 本身**（无独立 notification 句柄）：释放 iterator 即注销通知；
    /// - 注册成功后 iterator 已预装"当前已存在"的匹配项，**必须排干到 0 通知才 armed**，
    ///   否则后续事件永不触发回调；
    /// - `IOServiceMatching` 字典一经传入即被 API 消费（头文件标注 `CF_RELEASES_ARGUMENT`，
    ///   成功与否都不再归调用方所有），publish/terminate 两次注册各建一份，调用后不得释放。
    ///
    /// - Returns: teardown 闭包。任一步失败时半成品已就地清理、返回空 teardown（信号永不
    ///   触发 = 纯轮询退回）；teardown 必须恰好调用一次，逆序释放 iterator/port/refcon。
    private static func makeUSBEventSignal(signal: DispatchSemaphore) -> @Sendable () -> Void {
        // 1) 通知端口 + 专用串行 queue：publish/terminate 两路通知共用一个 port（同桥同生命周期，
        //    与电池桥互不依赖，teardown 各自独立）。
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            return {}
        }
        let queue = DispatchQueue(label: "CableKit.CableMonitor.USBHostDeviceMatch", qos: .utility)
        IONotificationPortSetDispatchQueue(port, queue)

        // refcon 携带共享信号量：存活期与注册期严格一致（teardown 最后一步才平衡 release）。
        let refcon = Unmanaged.passRetained(signal).toOpaque()

        // 事件回调：在通知 queue（回调线程）上排干 iterator——本次事件装载的匹配项逐项
        // IOObjectRelease 后 signal 一次。多台设备一次装载只 signal 一次：信号语义只是
        // "该重新采集了"。publish 项的释放放行新注册设备；terminate 项的释放放行待终止
        // 设备（不被通知再引用的设备才真正销毁）。
        let handler: IOServiceMatchingCallback = { refcon, iterator in
            guard let refcon else { return }
            var delivered = false
            var item = IOIteratorNext(iterator)
            while item != 0 {
                IOObjectRelease(item)
                delivered = true
                item = IOIteratorNext(iterator)
            }
            if delivered {
                Unmanaged<DispatchSemaphore>.fromOpaque(refcon).takeUnretainedValue().signal()
            }
        }

        // 2) publish（接入）+ terminate（断开）两套匹配通知；类型常量定义于 IOKitKeys.h，
        //    选择理由见类型注释。字典按所有权规则各建一份（见函数注释）。
        var publishIterator = io_iterator_t(0)
        var terminateIterator = io_iterator_t(0)

        guard let publishMatching = IOServiceMatching("IOUSBHostDevice") else {
            IONotificationPortDestroy(port)
            Unmanaged<DispatchSemaphore>.fromOpaque(refcon).release()
            return {}
        }
        var kr = IOServiceAddMatchingNotification(port, kIOPublishNotification, publishMatching, handler, refcon, &publishIterator)
        guard kr == KERN_SUCCESS else {
            IONotificationPortDestroy(port)
            Unmanaged<DispatchSemaphore>.fromOpaque(refcon).release()
            return {}
        }

        guard let terminateMatching = IOServiceMatching("IOUSBHostDevice") else {
            IOObjectRelease(publishIterator) // iterator 即通知句柄：释放即注销
            IONotificationPortDestroy(port)
            Unmanaged<DispatchSemaphore>.fromOpaque(refcon).release()
            return {}
        }
        kr = IOServiceAddMatchingNotification(port, kIOTerminatedNotification, terminateMatching, handler, refcon, &terminateIterator)
        guard kr == KERN_SUCCESS else {
            IOObjectRelease(publishIterator)
            IONotificationPortDestroy(port)
            Unmanaged<DispatchSemaphore>.fromOpaque(refcon).release()
            return {}
        }

        // 3) 初始排干：注册成功后 iterator 已预装当前全部 IOUSBHostDevice（内置 hub 等），
        //    不排干通知不 armed、handler 永不触发。按本模块约束 iterator 只在通知 queue
        //    （回调线程）上排干：经 queue.sync 派发到回调线程执行——iterator 不进入 Swift
        //    异步上下文、不跨入主等待循环。初始项是"注册前就存在"的设备，无变化语义，
        //    不 signal（首个快照本就由主循环先采集）。
        queue.sync {
            for armedIterator in [publishIterator, terminateIterator] {
                var item = IOIteratorNext(armedIterator)
                while item != 0 {
                    IOObjectRelease(item)
                    item = IOIteratorNext(armedIterator)
                }
            }
        }

        let registeredPublish = publishIterator
        let registeredTerminate = terminateIterator
        // 同上：port/refcon 装箱后再被 teardown 闭包捕获（IOKitPointerBox 说明见电池桥）。
        let portBox = IOKitPointerBox(pointer: port)
        let refconBox = IOKitPointerBox(pointer: refcon)
        return {
            IOObjectRelease(registeredPublish)                                 // a) 释放 iterator = 注销 publish 匹配通知
            IOObjectRelease(registeredTerminate)                               // b) 释放 iterator = 注销 terminate 匹配通知
            IONotificationPortDestroy(portBox.pointer)                         // c) 销毁端口并解除 queue 挂接（此后不可能再有回调）
            Unmanaged<DispatchSemaphore>.fromOpaque(refconBox.pointer).release() // d) 最后平衡 passRetained
        }
    }

    /// 等待一次事件信号（电池兴趣 / USB publish / USB terminate 任一来源，信号语义不区分
    /// 来源），最多 `timeout` 秒；信号与超时谁先到都返回（调用方一律采集，无需区分）。
    ///
    /// - 同步等待放在 detached utility 线程（GCD 线程池），不占 Swift 协作线程池；
    /// - 任务取消即时生效：onCancel → `signal()` 唤醒可能挂着的等待 → 循环的 isCancelled 检查退出。
    private static func waitForEventOrTimeout(_ semaphore: DispatchSemaphore, timeout: TimeInterval) async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                Task.detached(priority: .utility) {
                    _ = semaphore.blockUntilEventOrTimeout(timeout)
                    continuation.resume()
                }
            }
        } onCancel: {
            semaphore.signal() // 唤醒可能挂着的等待；多余的一次 signal 无害（等待方随即退出循环）
        }
    }

    /// 快照内容签名（不含 id/timestamp）。
    private struct ContentKey: Hashable {
        let usbDevices: [USBDeviceSnapshot]
        let power: PowerSnapshot?
        let displays: [DisplaySnapshot]
        let thunderboltDevices: [ThunderboltDeviceSnapshot]
        let sessions: [CableSession]
        let ports: [USBCPortSnapshot]
        let displayPortLinks: [DisplayPortLinkSnapshot]

        init(snapshot: CableSnapshot) {
            self.usbDevices = snapshot.usbDevices
            self.power = snapshot.power
            self.displays = snapshot.displays
            self.thunderboltDevices = snapshot.thunderboltDevices
            self.sessions = snapshot.sessions
            self.ports = snapshot.ports
            self.displayPortLinks = snapshot.displayPortLinks
        }
    }
}

/// `DispatchSemaphore.wait(timeout:)` 被标记为不可在 async 上下文直接调用；
/// 这里包一层同步函数，供 detached 线程刻意阻塞使用（≤ timeout，用完即弃，不占协作线程池）。
private extension DispatchSemaphore {
    func blockUntilEventOrTimeout(_ seconds: TimeInterval) -> Bool {
        wait(timeout: DispatchTime.now() + seconds) == .success
    }
}

/// IOKit C 指针类型（`IONotificationPortRef`/`OpaquePointer`、`UnsafeMutableRawPointer` 等）
/// 本身不满足 `Sendable`，但本文件里它们只在单个 teardown 闭包内被捕获、且按类型注释保证
/// 的"恰好调用一次"时序解引用，不存在并发访问——装箱后用 `@unchecked Sendable` 显式承诺
/// 这一人工验证的线程安全前提，消除编译器保守告警。
private struct IOKitPointerBox<Pointer>: @unchecked Sendable {
    let pointer: Pointer
}
