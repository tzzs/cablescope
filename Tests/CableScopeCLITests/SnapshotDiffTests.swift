import Foundation
import CableKit
import XCTest
@testable import CableScopeCLI

/// watch 子命令的快照差异计算测试。
final class SnapshotDiffTests: XCTestCase {
    /// 断言里写的是中文输出：钉死 CLI 语言，否则在英文系统（CI runner）上跟随系统切成英文。
    private var savedLocale = CLILanguage.locale

    override func setUp() {
        super.setUp()
        savedLocale = CLILanguage.locale
        CLILanguage.locale = Locale(identifier: "zh-Hans")
    }

    override func tearDown() {
        CLILanguage.locale = savedLocale
        super.tearDown()
    }

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
                      batteryAmperageMA: watts?.a,
                      batteryVoltageMV: 12_000,
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
                              displays: [DisplaySnapshot] = [], thunderbolt: [ThunderboltDeviceSnapshot] = [],
                              ports: [USBCPortSnapshot] = []) -> CableSnapshot {
        CableSnapshot(usbDevices: usb, power: power, displays: displays,
                      thunderboltDevices: thunderbolt, ports: ports)
    }

    /// 端口控制器快照（只关心 PD 协商档）。
    private func makePort(portID: String = "Port-USB-C@1",
                           winning: PDOPhase?) -> USBCPortSnapshot {
        USBCPortSnapshot(portID: portID,
                         controllerClass: "AppleHPMInterfaceType10",
                         portType: "USB-C",
                         plugOrientation: nil,
                         isActive: true,
                         hasActiveCable: true,
                         connectionCount: 1,
                         transportsSupported: [],
                         transportsProvisioned: [],
                         featuresEnabled: [],
                         eMarker: nil,
                         partner: nil,
                         powerSource: winning.map {
                             PDOPortPowerSnapshot(sourceName: "USB-PD", options: [$0], winning: $0)
                         })
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
        let old = makeSnapshot(power: makePower(watts: (20_000, 2_000))) // 电池侧 12V × 2A = 24.0 W
        // 变化 0.3W：不报告
        let small = SnapshotDiff.changes(from: old, to: makeSnapshot(power: makePower(watts: (20_000, 2_025))))
        XCTAssertTrue(small.isEmpty, "≤1W 的波动不应产生输出")
        // 变化 1.2W：报告
        let big = SnapshotDiff.changes(from: old, to: makeSnapshot(power: makePower(watts: (20_000, 2_100))))
        XCTAssertTrue(big.contains { $0.contains("功率 24.0 W → 25.2 W") }, "\(big)")
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

    /// 内置根 hub 没有 `LocationID` 属性，解析后为 0。多个这类设备此前会撞进同一个
    /// 字典桶，被 `uniquingKeysWith` 静默丢弃——表现为「插了个 U 盘却没有任何提示」。
    /// 配对键在 locationID == 0 时须退到 registryID。
    func testUSBDevicesWithZeroLocationIDDoNotCollide() {
        // 两个 locationID 均为 0、但 registryID 不同的设备（同为内置 hub 层）。
        let hubA = USBDeviceSnapshot(registryID: 101, locationID: 0, productName: "内置 Hub",
                                     vendorName: nil, vendorID: nil, productID: nil, serialNumber: nil,
                                     bcdUSB: nil, speed: nil)
        let hubB = USBDeviceSnapshot(registryID: 202, locationID: 0, productName: "第二个 Hub",
                                     vendorName: nil, vendorID: nil, productID: nil, serialNumber: nil,
                                     bcdUSB: nil, speed: nil)
        let old = makeSnapshot(usb: [hubA])
        let new = makeSnapshot(usb: [hubA, hubB])

        let changes = SnapshotDiff.changes(from: old, to: new)
        XCTAssertTrue(changes.contains { $0.contains("USB 接入") && $0.contains("第二个 Hub") },
                      "locationID=0 的第二个设备应被识别为接入：\(changes)")

        // 反向：第二个设备拔出时也应报「断开」，而不是被同桶的另一个设备顶掉。
        let removed = SnapshotDiff.changes(from: new, to: makeSnapshot(usb: [hubA]))
        XCTAssertTrue(removed.contains { $0.contains("USB 断开") && $0.contains("第二个 Hub") },
                      "locationID=0 的设备拔出应被识别：\(removed)")
    }

    /// 同端口换设备时仍应报「设备变更」而非「断开 + 接入」两条噪音——
    /// 这依赖 locationID 作主配对键，故上面那个兜底只在 locationID == 0 时生效。
    func testSamePortDeviceSwapReportsChangeNotDisconnectAndConnect() {
        let old = makeSnapshot(usb: [makeUSB(location: 0x14100000, name: "旧盘", bps: 480_000_000)])
        let new = makeSnapshot(usb: [makeUSB(location: 0x14100000, name: "新盘", bps: 480_000_000)])
        let changes = SnapshotDiff.changes(from: old, to: new)

        XCTAssertTrue(changes.contains { $0.contains("USB 设备变更") && $0.contains("旧盘") && $0.contains("新盘") },
                      "同端口换设备应报变更：\(changes)")
        XCTAssertFalse(changes.contains { $0.contains("USB 接入") || $0.contains("USB 断开") },
                       "同端口换设备不应同时报接入/断开：\(changes)")
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

    // MARK: 雷雳

    func testThunderboltAddAndRemove() {
        let dock = ThunderboltDeviceSnapshot(name: "Dock", vendorName: nil, linkSpeedLabel: nil, deviceType: nil)
        let ssd = ThunderboltDeviceSnapshot(name: "SSD", vendorName: nil, linkSpeedLabel: nil, deviceType: nil)

        let add = SnapshotDiff.changes(from: makeSnapshot(thunderbolt: [dock]),
                                       to: makeSnapshot(thunderbolt: [dock, ssd]))
        XCTAssertTrue(add.contains { $0.contains("雷雳接入") && $0.contains("SSD") })

        let remove = SnapshotDiff.changes(from: makeSnapshot(thunderbolt: [dock, ssd]),
                                          to: makeSnapshot(thunderbolt: [dock]))
        XCTAssertTrue(remove.contains { $0.contains("雷雳断开") && $0.contains("SSD") })
    }

    // MARK: PD 协商档（端口控制器直读）

    /// 之前没有协商档、现在有 → 报"协商开始"。
    func testPDONegotiationStarted() {
        let phase = PDOPhase(voltageMV: 20_000, maxCurrentMA: 5_000, maxPowerMW: 100_000, uuid: "b")
        let changes = SnapshotDiff.changes(from: makeSnapshot(ports: [makePort(winning: nil)]),
                                           to: makeSnapshot(ports: [makePort(winning: phase)]))
        XCTAssertTrue(changes.contains { $0.contains("PD 协商开始：20.0V / 5.0A · 100W") }, "\(changes)")
    }

    /// 协商档变了 → 报"档位 A → B"。
    func testPDONegotiationChanged() {
        let before = PDOPhase(voltageMV: 20_000, maxCurrentMA: 3_000, maxPowerMW: 60_000, uuid: "a")
        let after = PDOPhase(voltageMV: 20_000, maxCurrentMA: 5_000, maxPowerMW: 100_000, uuid: "b")
        let changes = SnapshotDiff.changes(from: makeSnapshot(ports: [makePort(winning: before)]),
                                           to: makeSnapshot(ports: [makePort(winning: after)]))
        XCTAssertTrue(changes.contains { $0.contains("PD 档位 20.0V / 3.0A · 60W → 20.0V / 5.0A · 100W") },
                      "\(changes)")
    }

    /// 协商档没变 → 不报（避免噪音）。
    func testPDONegotiationUnchangedIsSilent() {
        let phase = PDOPhase(voltageMV: 20_000, maxCurrentMA: 5_000, maxPowerMW: 100_000, uuid: "b")
        let changes = SnapshotDiff.changes(from: makeSnapshot(ports: [makePort(winning: phase)]),
                                           to: makeSnapshot(ports: [makePort(winning: phase)]))
        XCTAssertTrue(changes.isEmpty, "\(changes)")
    }

    // MARK: 基线摘要

    func testBaselineSummary() {
        let snapshot = makeSnapshot(usb: [makeUSB(location: 1, name: "SSD", bps: nil)],
                                    power: makePower(), displays: [makeDisplay()])
        let summary = SnapshotDiff.baselineSummary(snapshot)
        XCTAssertTrue(summary.contains("充电中"))
        XCTAssertTrue(summary.contains("USB ×1"))
        XCTAssertTrue(summary.contains("显示器 ×1"))
        XCTAssertTrue(summary.contains("雷雳 ×0"))
        // 无电源数据时优雅降级
        let bare = SnapshotDiff.baselineSummary(makeSnapshot())
        XCTAssertTrue(bare.contains("暂无数据"))
        // 端口控制器数据存在时基线里也要报端口数
        let withPorts = SnapshotDiff.baselineSummary(
            makeSnapshot(ports: [makePort(winning: nil)]))
        XCTAssertTrue(withPorts.contains("端口 ×1"), withPorts)
    }
}
