import CableKit
import Foundation
import XCTest
@testable import CableScopeCLI

/// `pretty` 子命令的人类可读输出（`CableScopeCLI.render`）。
///
/// 覆盖的是「渲染规则」：电源三种状态的分流、PD 档位/端口状态行、会话与设备的
/// 归属、显示器分区、空数据的降级文案。
final class PrettyRenderingTests: XCTestCase {
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

    private func render(_ snapshot: CableSnapshot) -> String {
        CLITestSupport.strippingANSI(CableScopeCLI.render(snapshot))
    }

    // MARK: 构件

    private func makeSnapshot(usb: [USBDeviceSnapshot] = [],
                              power: PowerSnapshot? = nil,
                              displays: [DisplaySnapshot] = [],
                              thunderbolt: [ThunderboltDeviceSnapshot] = [],
                              sessions: [CableSession] = [],
                              ports: [USBCPortSnapshot] = [],
                              displayPortLinks: [DisplayPortLinkSnapshot] = []) -> CableSnapshot {
        CableSnapshot(usbDevices: usb, power: power, displays: displays,
                      thunderboltDevices: thunderbolt, sessions: sessions, ports: ports,
                      displayPortLinks: displayPortLinks)
    }

    private func makePower(isCharging: Bool = true,
                           externalConnected: Bool? = nil,
                           voltageMV: Int? = 20_000,
                           currentMA: Int? = 2_014,
                           batteryVoltageMV: Int? = 12_000,
                           contract: PDContract? = PDContract(voltageMV: 20_000, currentMA: 5_000),
                           percent: Double? = 80,
                           cycles: Int? = 40,
                           adapter: String? = "pd charger") -> PowerSnapshot {
        PowerSnapshot(isCharging: isCharging,
                      batteryPercent: percent,
                      adapterVoltageMV: voltageMV,
                      batteryAmperageMA: currentMA,
                      batteryVoltageMV: batteryVoltageMV,
                      pdContract: contract,
                      adapterDescription: adapter,
                      cycleCount: cycles,
                      externalConnected: externalConnected ?? isCharging)
    }

    // MARK: 空数据降级

    func testEmptySnapshotShowsDegradedSections() {
        let text = render(makeSnapshot())

        XCTAssertTrue(text.contains("线缆端口 (0)"), text)
        XCTAssertTrue(text.contains("暂无数据"), text)
        XCTAssertTrue(text.contains("未检测到线缆 / 设备"), text)
        XCTAssertTrue(text.contains("未检测到显示器"), text)
    }

    private func makePort(portType: String? = "USB-C",
                          orientation: Int? = nil,
                          eMarker: EMarkerSnapshot? = nil,
                          transports: [String] = [],
                          powerSource: PDOPortPowerSnapshot? = nil) -> USBCPortSnapshot {
        USBCPortSnapshot(portID: "Port-USB-C@1",
                         controllerClass: "AppleHPMInterfaceType10",
                         portType: portType,
                         plugOrientation: orientation,
                         isActive: true,
                         hasActiveCable: true,
                         connectionCount: 1,
                         transportsSupported: transports,
                         transportsProvisioned: transports,
                         featuresEnabled: [],
                         eMarker: eMarker,
                         partner: nil,
                         powerSource: powerSource)
    }

    // MARK: 电源分区
    /// 充电中：标题带电池侧功率；适配器电压与电池电流分两行，不拼成一对。
    func testChargingHeadlineShowsBatteryPower() {
        let text = render(makeSnapshot(power: makePower()))
        XCTAssertTrue(text.contains("充电中  24.2 W"), text)
        XCTAssertTrue(text.contains("适配器电压  20.0 V"), text)
        XCTAssertTrue(text.contains("电池  12.0 V / 2.01 A"), text)
        XCTAssertTrue(text.contains("PD 合同  20.0 V × 5.00 A（至少支持 5A）"), text)
        XCTAssertTrue(text.contains("电量  80%"), text)
        XCTAssertTrue(text.contains("电池循环  40 次"), text)
        XCTAssertTrue(text.contains("适配器  pd charger"), text)
    }

    /// 插电但没在充电（保温/优化充电暂停）：瞬时功率无意义，改显 PD 合同能力。
    func testConnectedButNotChargingShowsContractCapability() {
        let power = makePower(isCharging: false, externalConnected: true,
                              voltageMV: 20_000, currentMA: -540)
        let text = render(makeSnapshot(power: power))
        XCTAssertTrue(text.contains("已接通电源（未在充电）  100.0 W"), text)
        XCTAssertFalse(text.contains("充电中  "), text)
    }

    /// 没插电：只说用电池，不显示任何数字。
    func testOnBatteryShowsNoPowerNumber() {
        let power = makePower(isCharging: false, externalConnected: false,
                              voltageMV: nil, currentMA: nil, contract: nil)
        let text = render(makeSnapshot(power: power))
        XCTAssertTrue(text.contains("未接通电源（使用电池）"), text)
        XCTAssertFalse(text.contains("PD 合同"), text)
    }

    /// 适配器电压/电池电流缺失时不编造"电压/电流"一对，只留 PD 合同那一行。
    func testNoMixedVoltageCurrentPairWhenAdapterValuesAreMissing() {
        let power = makePower(isCharging: false, externalConnected: true,
                              voltageMV: nil, currentMA: nil)
        let text = render(makeSnapshot(power: power))
        XCTAssertFalse(text.contains("适配器电压"), text)
        XCTAssertFalse(text.contains("电压/电流"), text)
        XCTAssertTrue(text.contains("PD 合同  20.0 V × 5.00 A"), text)
    }

    // MARK: PD 档位

    /// 档位表带 negotiated 标记。
    func testPDOTiersMarkTheWinningOption() {
        let port = makePort(powerSource: PDOPortPowerSnapshot(
            sourceName: "USB-PD",
            options: [
                PDOPhase(voltageMV: 5_000, maxCurrentMA: 3_000, maxPowerMW: 15_000, uuid: "a"),
                PDOPhase(voltageMV: 20_000, maxCurrentMA: 5_000, maxPowerMW: 100_000, uuid: "b"),
            ],
            winning: PDOPhase(voltageMV: 20_000, maxCurrentMA: 5_000, maxPowerMW: 100_000, uuid: "b")))
        let text = render(makeSnapshot(power: makePower(), ports: [port]))

        XCTAssertTrue(text.contains("PD 档位  5.0V / 3.0A · 15W · *20.0V / 5.0A · 100W"), text)
    }

    // MARK: 会话分区

    func testSessionShowsPortLabelAndDevices() {
        let device = USBDeviceSnapshot(registryID: 7, locationID: 0x14000000,
                                       physicalPortID: "Port-USB-C@1",
                                       productName: "SSD", vendorName: nil,
                                       vendorID: nil, productID: nil, serialNumber: nil,
                                       bcdUSB: nil, speed: USBSpeed(bitsPerSecond: 10_000_000_000))
        let session = CableSession(id: "usb-0x140", kind: .usb, portKey: 0x140,
                                   physicalPortID: "Port-USB-C@1", portType: "USB-C",
                                   usbDevices: [device])
        let text = render(makeSnapshot(usb: [device], sessions: [session]))

        XCTAssertTrue(text.contains("线缆端口 (1)"), text)
        XCTAssertTrue(text.contains("▸ USB-C 端口 @1  [usb-0x140]"), text)
        XCTAssertTrue(text.contains("• SSD  10000 Mbps → USB 3.x Gen2 10 Gbps"), text)
    }

    /// 端口会话没有设备时给一句"（无设备）"——纯 PD 充电线就是这种形态。
    func testSessionWithoutDevicesSaysSo() {
        let session = CableSession(id: "Port-USB-C@1", kind: .usb, portKey: nil,
                                   physicalPortID: "Port-USB-C@1", portType: "USB-C")
        let text = render(makeSnapshot(sessions: [session]))

        XCTAssertTrue(text.contains("（无设备）"), text)
    }

    /// 端口状态行：形态 / 插头方向 / e-marker / USB4 能力。
    func testPortStatusLineDescribesThePort() {
        let port = makePort(portType: "USB-C", orientation: 1,
                            eMarker: EMarkerSnapshot(vendorID: 0x05AC, productID: 0x1234,
                                                    productType: 3,
                                                    productTypeDescription: "Passive Cable",
                                                    vdos: [0x1800_0000, 0, 0, 0x40]),
                            transports: ["CIO", "USB3"])
        let session = CableSession(id: "Port-USB-C@1", kind: .usb, portKey: nil,
                                   physicalPortID: "Port-USB-C@1", portType: "USB-C")
        let text = render(makeSnapshot(sessions: [session], ports: [port]))

        XCTAssertTrue(text.contains("端口：USB-C · 插头方向 A · 被动线缆 · 5A（≤100W） · USB4/雷雳可用"), text)
    }

    /// 雷雳设备：厂商、链路速度与代际都进展示行。
    func testThunderboltDeviceLineIncludesVendorSpeedAndGeneration() {
        let dock = ThunderboltDeviceSnapshot(name: "Dock", vendorName: "Apple",
                                            linkSpeedLabel: "40 Gb/s", deviceType: nil,
                                            receptaclePort: 2, generation: "雷雳 4 / USB4", depth: 0)
        let session = CableSession(id: "tb-2", kind: .thunderbolt, receptaclePort: 2,
                                   thunderboltDevices: [dock])
        let text = render(makeSnapshot(thunderbolt: [dock], sessions: [session]))

        XCTAssertTrue(text.contains("▸ 雷雳端口 2  [tb-2]"), text)
        XCTAssertTrue(text.contains("• Dock  Apple · 40 Gb/s · 雷雳 4 / USB4"), text)
    }

    // MARK: DisplayPort 链路

    /// 能精确匹配到显示器时展示分辨率/刷新率。
    func testDisplayPortLinkShowsMatchedDisplayResolution() {
        let link = DisplayPortLinkSnapshot(portID: "Port-USB-C@1", isActive: true, isTunneled: false,
                                           linkRateDescription: "8.1 Gbps (HBR3)",
                                           manufacturerName: "Dell", productName: "U2723QE",
                                           productID: 0x1234, serialNumber: nil)
        let display = DisplaySnapshot(displayID: 5, name: "DELL U2723QE", pixelWidth: 3840,
                                      pixelHeight: 2160, refreshRateHz: 60, linkRateLabel: nil,
                                      isMain: false, isBuiltin: false,
                                      vendorNumber: nil, modelNumber: 0x1234, serialNumber: nil)
        let session = CableSession(id: "Port-USB-C@1", kind: .usb, portKey: nil,
                                   physicalPortID: "Port-USB-C@1", portType: "USB-C")
        let text = render(makeSnapshot(displays: [display], sessions: [session],
                                       displayPortLinks: [link]))

        XCTAssertTrue(text.contains("🖥 Dell U2723QE  3840×2160 · 60 Hz · 8.1 Gbps (HBR3)"), text)
    }

    /// 匹配不上显示器时只说分辨率未知，不猜。
    func testDisplayPortLinkWithoutMatchedDisplaySaysUnknownResolution() {
        let link = DisplayPortLinkSnapshot(portID: "Port-USB-C@1", isActive: true, isTunneled: false,
                                           linkRateDescription: nil,
                                           manufacturerName: nil, productName: nil,
                                           productID: nil, serialNumber: nil)
        let session = CableSession(id: "Port-USB-C@1", kind: .usb, portKey: nil,
                                   physicalPortID: "Port-USB-C@1", portType: "USB-C")
        let text = render(makeSnapshot(sessions: [session], displayPortLinks: [link]))

        XCTAssertTrue(text.contains("🖥 外接显示器  分辨率未知"), text)
    }

    // MARK: 显示器分区

    func testDisplaySectionShowsResolutionRateLinkAndMainMarker() {
        let display = DisplaySnapshot(displayID: 1, name: "DELL U2723QE", pixelWidth: 3840,
                                      pixelHeight: 2160, refreshRateHz: 60, linkRateLabel: "hbr3",
                                      isMain: true)
        let text = render(makeSnapshot(displays: [display]))

        XCTAssertTrue(text.contains("• DELL U2723QE  3840×2160 · 60 Hz · 链路 hbr3 · 主显示器"), text)
    }

    /// 内建屏用我们自己的文案（系统名跟随系统语言，不能直接用）。
    func testBuiltinDisplayUsesOurOwnLabel() {
        let display = DisplaySnapshot(displayID: 1, name: "内建视网膜显示器", pixelWidth: 2940,
                                      pixelHeight: 1912, refreshRateHz: 120, linkRateLabel: nil,
                                      isMain: true, isBuiltin: true)
        let text = render(makeSnapshot(displays: [display]))

        XCTAssertTrue(text.contains("• 内建显示器  2940×1912 · 120 Hz · 主显示器"), text)
        XCTAssertFalse(text.contains("内建视网膜显示器"), text)
    }

    // MARK: JSON 输出

    func testSnapshotJSONTextIsCompactByDefaultAndPrettyOnDemand() throws {
        let snapshot = makeSnapshot(usb: [
            USBDeviceSnapshot(registryID: 1, locationID: 0x14000000, productName: "SSD",
                              vendorName: nil, vendorID: nil, productID: nil, serialNumber: nil,
                              bcdUSB: nil, speed: nil),
        ])

        let compact = try CableScopeCLI.jsonText(snapshot, pretty: false)
        XCTAssertFalse(compact.contains("\n"), "紧凑输出应是一行")
        let object = try JSONSerialization.jsonObject(with: Data(compact.utf8)) as? [String: Any]
        XCTAssertNotNil(object?["usbDevices"])
        XCTAssertNotNil(object?["timestamp"])

        let pretty = try CableScopeCLI.jsonText(snapshot, pretty: true)
        XCTAssertTrue(pretty.contains("\n"), "美化输出应是多行")
    }
}
