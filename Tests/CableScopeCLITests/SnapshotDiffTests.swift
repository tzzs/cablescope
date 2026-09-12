import CableKit
import XCTest
@testable import CableScopeCLI

/// watch 子命令的快照差异计算测试。
final class SnapshotDiffTests: XCTestCase {
    private func makeUSB(location: UInt32, name: String, bps: Int?) -> USBDeviceSnapshot {
        USBDeviceSnapshot(registryID: UInt64(location), locationID: location, productName: name,
                          vendorName: nil, vendorID: nil, productID: nil, serialNumber: nil,
                          bcdUSB: nil, speed: bps.map { USBSpeed(bitsPerSecond: $0) })
    }

    private func makePower(charging: Bool = true, watts: (v: Int, a: Int)? = (20_000, 2_000),
                           percent: Double? = 80,
                           contract: PDContract? = PDContract(voltageMV: 20_000, currentMA: 5_000)) -> PowerSnapshot {
        PowerSnapshot(isCharging: charging,
                      batteryPercent: percent,
                      adapterVoltageMV: watts?.v,
                      adapterAmperageMA: watts?.a,
                      pdContract: contract,
                      adapterDescription: nil,
                      cycleCount: nil)
    }

    private func makeDisplay(id: UInt32 = 1, width: Int = 3840, height: Int = 2160,
                             hz: Double? = 60, link: String? = nil, main: Bool = true) -> DisplaySnapshot {
        DisplaySnapshot(displayID: id, name: "Display", pixelWidth: width, pixelHeight: height,
                        refreshRateHz: hz, linkRateLabel: link, isMain: main)
    }

    private func makeSnapshot(usb: [USBDeviceSnapshot] = [], power: PowerSnapshot? = nil,
                              displays: [DisplaySnapshot] = [], thunderbolt: [ThunderboltDeviceSnapshot] = []) -> CableSnapshot {
        CableSnapshot(usbDevices: usb, power: power, displays: displays, thunderboltDevices: thunderbolt)
    }

    // MARK: 电源

    func testNoChangesProducesEmptyDiff() {
        let old = makeSnapshot(power: makePower(), displays: [makeDisplay()])
        let new = makeSnapshot(power: makePower(), displays: [makeDisplay()])
        XCTAssertEqual(SnapshotDiff.changes(from: old, to: new), [])
    }

    func testPowerAppearsAndDisappears() {
        let changes = SnapshotDiff.changes(from: makeSnapshot(power: nil),
                                           to: makeSnapshot(power: makePower()))
        XCTAssertTrue(changes.contains { $0.contains("电源信息可用") })

        let reverse = SnapshotDiff.changes(from: makeSnapshot(power: makePower()),
                                           to: makeSnapshot(power: nil))
        XCTAssertTrue(reverse.contains { $0.contains("电源信息不可用") })
    }

    func testChargingToggle() {
        let changes = SnapshotDiff.changes(from: makeSnapshot(power: makePower(charging: true)),
                                           to: makeSnapshot(power: makePower(charging: false)))
        XCTAssertTrue(changes.contains { $0.contains("已停止充电") })
    }

    func testWattsChangeThresholdIsOneWatt() {
        let old = makeSnapshot(power: makePower(watts: (20_000, 2_000))) // 40.0 W
        // 变化 0.5W：不报告
        let small = SnapshotDiff.changes(from: old, to: makeSnapshot(power: makePower(watts: (20_000, 2_025))))
        XCTAssertTrue(small.isEmpty, "≤1W 的波动不应产生输出")
        // 变化 1.5W：报告
        let big = SnapshotDiff.changes(from: old, to: makeSnapshot(power: makePower(watts: (20_000, 2_075))))
        XCTAssertTrue(big.contains { $0.contains("功率 40.0 W → 41.5 W") })
    }

    func testWattsReportingStartsAndStops() {
        let appears = SnapshotDiff.changes(from: makeSnapshot(power: makePower(watts: nil)),
                                           to: makeSnapshot(power: makePower()))
        XCTAssertTrue(appears.contains { $0.contains("功率开始上报") })

        let stops = SnapshotDiff.changes(from: makeSnapshot(power: makePower()),
                                         to: makeSnapshot(power: makePower(watts: nil)))
        XCTAssertTrue(stops.contains { $0.contains("功率不再上报") })
    }

    func testPDContractChange() {
        let old = makeSnapshot(power: makePower(contract: PDContract(voltageMV: 20_000, currentMA: 3_000)))
        let new = makeSnapshot(power: makePower(contract: PDContract(voltageMV: 20_000, currentMA: 5_000)))
        let changes = SnapshotDiff.changes(from: old, to: new)
        XCTAssertTrue(changes.contains { $0.contains("PD 合同 20.0 V × 3.00 A → 20.0 V × 5.00 A") })
    }

    func testBatteryPercentChange() {
        let changes = SnapshotDiff.changes(from: makeSnapshot(power: makePower(percent: 80)),
                                           to: makeSnapshot(power: makePower(percent: 79)))
        XCTAssertTrue(changes.contains { $0.contains("电量 80% → 79%") })
    }

    // MARK: USB

    func testUSBConnectDisconnectAndSpeedChange() {
        let old = makeSnapshot(usb: [makeUSB(location: 0x14100000, name: "SSD", bps: 480_000_000)])
        let new = makeSnapshot(usb: [
            makeUSB(location: 0x14200000, name: "新设备", bps: 10_000_000_000),
            makeUSB(location: 0x14100000, name: "SSD", bps: 10_000_000_000),
        ])
        let changes = SnapshotDiff.changes(from: old, to: new)

        XCTAssertTrue(changes.contains { $0.contains("USB 接入") && $0.contains("新设备") })
        XCTAssertTrue(changes.contains { $0.contains("USB 速率 480 Mbps → 10 Gbps") }, "同端口速率变化：\(changes)")
        // 断开检查：把 new 换回只有老设备
        let removed = SnapshotDiff.changes(from: old, to: makeSnapshot(usb: []))
        XCTAssertTrue(removed.contains { $0.contains("USB 断开") && $0.contains("SSD") })
    }

    func testUSBUnknownToKnownSpeed() {
        let old = makeSnapshot(usb: [makeUSB(location: 1, name: "SSD", bps: nil)])
        let new = makeSnapshot(usb: [makeUSB(location: 1, name: "SSD", bps: 5_000_000_000)])
        let changes = SnapshotDiff.changes(from: old, to: new)
        XCTAssertTrue(changes.contains { $0.contains("USB 速率未知 → 5 Gbps") })
    }

    // MARK: 显示器

    func testDisplayChanges() {
        let old = makeSnapshot(displays: [makeDisplay(hz: 60, link: nil, main: true)])
        let new = makeSnapshot(displays: [makeDisplay(width: 1920, height: 1080, hz: 120, link: "hbr3", main: true)])
        let changes = SnapshotDiff.changes(from: old, to: new)

        XCTAssertTrue(changes.contains { $0.contains("分辨率 3840×2160 → 1920×1080") })
        XCTAssertTrue(changes.contains { $0.contains("刷新率 60 Hz → 120 Hz") })
        XCTAssertTrue(changes.contains { $0.contains("DP 链路 未知 → hbr3") })
    }

    func testMainDisplaySwitch() {
        let old = makeSnapshot(displays: [makeDisplay(id: 1, main: true), makeDisplay(id: 2, main: false)])
        let new = makeSnapshot(displays: [makeDisplay(id: 1, main: false), makeDisplay(id: 2, main: true)])
        let changes = SnapshotDiff.changes(from: old, to: new)
        XCTAssertTrue(changes.contains { $0.contains("主显示器切换") })
    }

    func testDisplayConnectDisconnect() {
        let connect = SnapshotDiff.changes(from: makeSnapshot(), to: makeSnapshot(displays: [makeDisplay()]))
        XCTAssertTrue(connect.contains { $0.contains("显示器接入") })

        let disconnect = SnapshotDiff.changes(from: makeSnapshot(displays: [makeDisplay()]), to: makeSnapshot())
        XCTAssertTrue(disconnect.contains { $0.contains("显示器断开") })
    }

    // MARK: 雷电

    func testThunderboltAddAndRemove() {
        let dock = ThunderboltDeviceSnapshot(name: "Dock", vendorName: nil, linkSpeedLabel: nil, deviceType: nil)
        let ssd = ThunderboltDeviceSnapshot(name: "SSD", vendorName: nil, linkSpeedLabel: nil, deviceType: nil)

        let add = SnapshotDiff.changes(from: makeSnapshot(thunderbolt: [dock]),
                                       to: makeSnapshot(thunderbolt: [dock, ssd]))
        XCTAssertTrue(add.contains { $0.contains("雷电接入") && $0.contains("SSD") })

        let remove = SnapshotDiff.changes(from: makeSnapshot(thunderbolt: [dock, ssd]),
                                          to: makeSnapshot(thunderbolt: [dock]))
        XCTAssertTrue(remove.contains { $0.contains("雷电断开") && $0.contains("SSD") })
    }

    // MARK: 基线摘要

    func testBaselineSummary() {
        let snapshot = makeSnapshot(usb: [makeUSB(location: 1, name: "SSD", bps: nil)],
                                    power: makePower(), displays: [makeDisplay()])
        let summary = SnapshotDiff.baselineSummary(snapshot)
        XCTAssertTrue(summary.contains("充电中"))
        XCTAssertTrue(summary.contains("USB ×1"))
        XCTAssertTrue(summary.contains("显示器 ×1"))
        XCTAssertTrue(summary.contains("雷电 ×0"))
        // 无电源数据时优雅降级
        let bare = SnapshotDiff.baselineSummary(makeSnapshot())
        XCTAssertTrue(bare.contains("暂无数据"))
    }
}
