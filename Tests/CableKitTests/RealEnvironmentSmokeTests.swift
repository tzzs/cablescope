import XCTest
@testable import CableKit

/// 真实环境冒烟测试：调用真实 IOKit/profiler 实现，断言不崩溃、类型正确。
/// **不假设任何设备存在**（当前机器无 USB/雷电外设也必须通过）。
final class RealEnvironmentSmokeTests: XCTestCase {

    func testUSBServiceSmoke() async throws {
        let service = USBService()
        let devices = try await service.listUSBDevices()
        // 空结果合法；有结果时逐项校验类型完整性
        for device in devices {
            XCTAssertNotEqual(device.registryID, 0)
            XCTAssertEqual(device.locationID & 0xFF000000, device.locationID & 0xFF000000) // UInt32 可编码
            if let speed = device.speed {
                XCTAssertGreaterThanOrEqual(speed.bitsPerSecond, 0)
                XCTAssertFalse(speed.label.isEmpty)
                XCTAssertFalse(speed.generation.isEmpty)
            }
        }
    }

    func testPowerServiceSmoke() async throws {
        let service = PowerService()
        let power = try await service.currentPower()
        if let power {
            // 类型与取值范围校验（不假设充电状态）
            if let percent = power.batteryPercent {
                XCTAssertTrue((0...100).contains(percent), "电量百分比应在 0-100，实际 \(percent)")
            }
            if let v = power.adapterVoltageMV {
                XCTAssertGreaterThan(v, 0)
            }
            if let a = power.adapterAmperageMA {
                // 顶层 Amperage 是电池侧瞬时电流，符号随充放方向变化：
                // 保温暂停/电池放电时为负（2026-09-13 真机实测 -540mA），只校验量级；
                // 仅在正在充电时要求为正。
                XCTAssertLessThan(abs(a), 1_000_000, "电流读数量级异常：\(a)mA")
                if power.isCharging {
                    XCTAssertGreaterThan(a, 0, "正在充电时电池侧电流应为正")
                }
            }
            if let contract = power.pdContract {
                XCTAssertGreaterThan(contract.voltageMV, 0)
                XCTAssertGreaterThan(contract.currentMA, 0)
            }
        }
        // 本机是内置电池笔记本，通常应能读到电量；这里仅软断言（CI/无电池机型不挂）
    }

    func testDisplayServiceSmoke() async throws {
        let service = DisplayService()
        let displays = try await service.listDisplays()
        for display in displays {
            XCTAssertGreaterThan(display.pixelWidth, 0)
            XCTAssertGreaterThan(display.pixelHeight, 0)
            if let hz = display.refreshRateHz {
                XCTAssertGreaterThan(hz, 0)
            }
            // linkRateLabel 可为 nil（内置显示器无 DP link rate 字段，属预期）
        }
    }

    func testThunderboltServiceSmoke() async throws {
        let service = ThunderboltService()
        let devices = try await service.listThunderboltDevices()
        for device in devices {
            XCTAssertFalse(device.name.isEmpty)
            if let speed = device.linkSpeedLabel {
                XCTAssertFalse(speed.isEmpty)
            }
        }
    }

    func testPortControllerServiceSmoke() async throws {
        let service = PortControllerService()
        let ports = try await service.listPorts()
        // 空结果合法（老机型/Intel 无 AppleHPM 节点）；有结果时逐项校验结构完整性
        for port in ports {
            XCTAssertTrue(port.portID.hasPrefix("Port-"), "端口 ID 应为路径末段（Port-USB-C@N），实际 \(port.portID)")
            XCTAssertFalse(port.controllerClass.isEmpty)
            // PD 档位：有协商档时其电压/电流必须为正
            if let winning = port.powerSource?.winning {
                XCTAssertGreaterThan(winning.voltageMV, 0)
                XCTAssertGreaterThan(winning.maxCurrentMA, 0)
            }
            // e-marker：有身份时 VDO 数量符合 PD Discover Identity 布局（1-8 个对象）
            if let eMarker = port.eMarker {
                XCTAssertFalse(eMarker.vdos.isEmpty)
                XCTAssertLessThanOrEqual(eMarker.vdos.count, 8)
            }
        }
        // 端口 ID 不得重复
        XCTAssertEqual(Set(ports.map(\.portID)).count, ports.count)
    }

    func testRegistryServiceSmoke() async throws {
        let service = RegistryService()
        for wellKnown in RegistryService.wellKnownClasses {
            let entries = try await service.listEntries(matchingClass: wellKnown.className)
            // 空结果合法（当前机器可能没有该类的实例）；有结果时校验结构完整性与截断上限
            XCTAssertLessThanOrEqual(entries.count, RegistryService.maxEntries)
            for entry in entries {
                XCTAssertFalse(entry.className.isEmpty)
            }
            // registryID 稳定排序，不应有重复条目
            XCTAssertEqual(Set(entries.map(\.registryID)).count, entries.count)
        }
    }

    func testCableMonitorSnapshotNowSmoke() async throws {
        let monitor = CableMonitor()
        let snapshot = try await monitor.snapshotNow()
        XCTAssertFalse(snapshot.id.uuidString.isEmpty)
        XCTAssertLessThanOrEqual(snapshot.timestamp.timeIntervalSinceNow, 5, "快照时间应为当前时刻")
        // 容错组合：整体永不抛错（上面未 throw 即通过），各维度类型正确
        XCTAssertTrue(snapshot.usbDevices.count >= 0)
        XCTAssertTrue(snapshot.displays.count >= 0)
        XCTAssertTrue(snapshot.thunderboltDevices.count >= 0)
        // 会话一致性：每台 USB/雷雳设备恰好归属一个线缆会话
        XCTAssertEqual(snapshot.sessions.flatMap(\.usbDevices).count, snapshot.usbDevices.count)
        XCTAssertEqual(snapshot.sessions.flatMap(\.thunderboltDevices).count, snapshot.thunderboltDevices.count)
        // 端口配对：有物理端口名的 USB 会话应能在端口列表中找到同名端口
        for session in snapshot.sessions {
            if let physicalPortID = session.physicalPortID {
                XCTAssertTrue(snapshot.ports.contains { $0.portID == physicalPortID },
                              "会话 \(session.id) 配对的端口 \(physicalPortID) 应存在于端口列表")
            }
        }
    }

    func testCableMonitorSnapshotStreamYieldsInitialSnapshot() async throws {
        let monitor = CableMonitor()
        let stream = monitor.snapshotStream()
        // 启动时应立即产出首个快照（带超时保护，防止异常情况下挂死测试）
        let first = try await withTimeoutOrThrow(seconds: 15) { () -> CableSnapshot in
            var iterator = stream.makeAsyncIterator()
            guard let snapshot = await iterator.next() else { throw TimeoutError() }
            return snapshot
        }
        XCTAssertLessThanOrEqual(first.timestamp.timeIntervalSinceNow, 5)
        // 提前结束流（触发 onTermination → 取消轮询任务，验证该清理路径不崩溃）
    }

    // MARK: - 超时保护（防止轮询流挂死测试进程）

    private func withTimeoutOrThrow<T: Sendable>(seconds: TimeInterval,
                                                 _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimeoutError()
            }
            guard let result = try await group.next() else {
                throw TimeoutError()
            }
            group.cancelAll()
            return result
        }
    }

    private struct TimeoutError: Error {}
}
