import XCTest
@testable import CableKit

/// NotificationDiff 的表驱动测试：覆盖冷启动基线、插拔、充电状态切换、
/// USB 速率提升、首次 5A 确认、DP 链路提升，以及"无意义字段变化不误报"的回归。
final class NotificationDiffTests: XCTestCase {
    private func session(id: String, portKey: UInt32, device: USBDeviceSnapshot?) -> CableSession {
        CableSession(id: id, kind: .usb, portKey: portKey,
                     usbDevices: device.map { [$0] } ?? [])
    }

    private func device(locationID: UInt32, speed: USBSpeed?) -> USBDeviceSnapshot {
        USBDeviceSnapshot(registryID: 1, locationID: locationID, productName: "Dev",
                          vendorName: nil, vendorID: nil, productID: nil, serialNumber: nil,
                          bcdUSB: nil, speed: speed)
    }

    private func power(charging: Bool) -> PowerSnapshot {
        PowerSnapshot(isCharging: charging, batteryPercent: 50,
                     adapterVoltageMV: charging ? 20_000 : nil, adapterAmperageMA: charging ? 3_000 : nil,
                     pdContract: charging ? PDContract(voltageMV: 20_000, currentMA: 3_000) : nil,
                     adapterDescription: nil, cycleCount: nil, externalConnected: charging)
    }

    private func snapshot(sessionID: String = "usb-0x141", portKey: UInt32 = 0x141,
                          speed: USBSpeed?, charging: Bool) -> CableSnapshot {
        let dev = device(locationID: portKey << 20, speed: speed)
        return CableSnapshot(usbDevices: [dev], power: power(charging: charging),
                             displays: [], thunderboltDevices: [],
                             sessions: [session(id: sessionID, portKey: portKey, device: dev)])
    }

    /// 冷启动（baseline == nil）：无论插拔还是充电状态，都只建立基线、不产生事件——
    /// 同时覆盖"插拔首个快照不通知"现状和"新事件类型冷启动不该狂发"的新要求。
    func testColdStartProducesNoEvents() {
        var engine = CableRatingEngine()
        let snap = snapshot(speed: USBSpeed(bitsPerSecond: 480_000_000), charging: true)
        engine.record(snap)

        let (events, baseline) = NotificationDiff.diff(baseline: nil, snapshot: snap, ratingEngine: engine)
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(baseline.sessionIDs, ["usb-0x141"])
        XCTAssertTrue(baseline.isCharging)
    }

    func testSessionConnectedAndDisconnected() {
        var engine = CableRatingEngine()
        let empty = CableSnapshot(usbDevices: [], power: nil, displays: [], thunderboltDevices: [], sessions: [])
        engine.record(empty)
        let (_, baseline0) = NotificationDiff.diff(baseline: nil, snapshot: empty, ratingEngine: engine)

        let connected = snapshot(speed: USBSpeed(bitsPerSecond: 480_000_000), charging: false)
        engine.record(connected)
        let (events1, baseline1) = NotificationDiff.diff(baseline: baseline0, snapshot: connected, ratingEngine: engine)
        XCTAssertEqual(events1, [.sessionConnected(sessionID: "usb-0x141")])

        engine.record(empty)
        let (events2, _) = NotificationDiff.diff(baseline: baseline1, snapshot: empty, ratingEngine: engine)
        XCTAssertEqual(events2, [.sessionDisconnected(sessionID: "usb-0x141")])
    }

    func testChargingStartedAndStopped() {
        var engine = CableRatingEngine()
        let notCharging = snapshot(speed: nil, charging: false)
        engine.record(notCharging)
        let (_, baseline0) = NotificationDiff.diff(baseline: nil, snapshot: notCharging, ratingEngine: engine)

        let charging = snapshot(speed: nil, charging: true)
        engine.record(charging)
        let (events1, baseline1) = NotificationDiff.diff(baseline: baseline0, snapshot: charging, ratingEngine: engine)
        XCTAssertEqual(events1, [.chargingStarted])

        engine.record(notCharging)
        let (events2, _) = NotificationDiff.diff(baseline: baseline1, snapshot: notCharging, ratingEngine: engine)
        XCTAssertEqual(events2, [.chargingStopped])
    }

    func testUSBSpeedUpgrade() {
        var engine = CableRatingEngine()
        let slow = snapshot(speed: USBSpeed(bitsPerSecond: 480_000_000), charging: false)
        engine.record(slow)
        let (_, baseline0) = NotificationDiff.diff(baseline: nil, snapshot: slow, ratingEngine: engine)

        let fast = snapshot(speed: USBSpeed(bitsPerSecond: 10_000_000_000), charging: false)
        engine.record(fast)
        let (events, _) = NotificationDiff.diff(baseline: baseline0, snapshot: fast, ratingEngine: engine)
        XCTAssertEqual(events, [.usbSpeedUpgraded(sessionID: "usb-0x141",
                                                   to: USBSpeed(bitsPerSecond: 10_000_000_000))])
    }

    /// 首次出现 20V/5A 合同 ⇒ e-marker 5A 线推断，属于"评级提升"。
    func testFirstFiveAmpConfirmedIsRatingUpgrade() {
        var engine = CableRatingEngine()
        let threeAmp = CableSnapshot(usbDevices: [], power: PowerSnapshot(
            isCharging: true, batteryPercent: 50, adapterVoltageMV: 20_000, adapterAmperageMA: 3_000,
            pdContract: PDContract(voltageMV: 20_000, currentMA: 3_000),
            adapterDescription: nil, cycleCount: nil, externalConnected: true),
            displays: [], thunderboltDevices: [],
            sessions: [session(id: "usb-0x141", portKey: 0x141, device: nil)])
        engine.record(threeAmp)
        let (_, baseline0) = NotificationDiff.diff(baseline: nil, snapshot: threeAmp, ratingEngine: engine)

        let fiveAmp = CableSnapshot(usbDevices: [], power: PowerSnapshot(
            isCharging: true, batteryPercent: 50, adapterVoltageMV: 20_000, adapterAmperageMA: 5_000,
            pdContract: PDContract(voltageMV: 20_000, currentMA: 5_000),
            adapterDescription: nil, cycleCount: nil, externalConnected: true),
            displays: [], thunderboltDevices: [],
            sessions: [session(id: "usb-0x141", portKey: 0x141, device: nil)])
        engine.record(fiveAmp)
        let (events, _) = NotificationDiff.diff(baseline: baseline0, snapshot: fiveAmp, ratingEngine: engine)
        XCTAssertEqual(events, [.ratingUpgraded(sessionID: "usb-0x141", dimension: .fiveAmpConfirmed)])
    }

    /// 新会话（刚插上）不应重复报"提升"——已经有 sessionConnected 了。
    func testNewSessionDoesNotAlsoReportUpgrade() {
        var engine = CableRatingEngine()
        let empty = CableSnapshot(usbDevices: [], power: nil, displays: [], thunderboltDevices: [], sessions: [])
        engine.record(empty)
        let (_, baseline0) = NotificationDiff.diff(baseline: nil, snapshot: empty, ratingEngine: engine)

        let connected = snapshot(speed: USBSpeed(bitsPerSecond: 10_000_000_000), charging: false)
        engine.record(connected)
        let (events, _) = NotificationDiff.diff(baseline: baseline0, snapshot: connected, ratingEngine: engine)
        XCTAssertEqual(events, [.sessionConnected(sessionID: "usb-0x141")],
                       "新插入的线不应同时报 usbSpeedUpgraded")
    }

    /// 回归：sampleCount/lastSeen 每次采样都变，但没有任何能力提升时不应误报"提升"。
    func testNoSpuriousUpgradeWhenNothingChanges() {
        var engine = CableRatingEngine()
        let snap = snapshot(speed: USBSpeed(bitsPerSecond: 480_000_000), charging: true)
        engine.record(snap)
        let (_, baseline0) = NotificationDiff.diff(baseline: nil, snapshot: snap, ratingEngine: engine)

        // 再采一次完全相同的快照：sampleCount 递增，但没有任何维度真正变强。
        engine.record(snap)
        let (events, _) = NotificationDiff.diff(baseline: baseline0, snapshot: snap, ratingEngine: engine)
        XCTAssertTrue(events.isEmpty, "字段抖动（sampleCount 等）不应产生提升事件：\(events)")
    }
}
