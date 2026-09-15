import XCTest
@testable import CableKit

/// 物理端口分组与线缆会话测试（纯函数 + JSON 兼容，无 IO 依赖）。
final class PortGroupingTests: XCTestCase {

    // MARK: - LocationID → 端口键 / hub 深度

    func testPortKeyKeepsBusAndRootPortNibble() {
        // bits 31-24 = 总线，bits 23-20 = 根端口：>> 20 保留这两段
        XCTAssertEqual(PortGrouping.portKey(forLocationID: 0x14100000), 0x141)
        XCTAssertEqual(PortGrouping.portKey(forLocationID: 0x14130000), 0x141, "经 hub 级联的设备同属一个物理端口")
        XCTAssertEqual(PortGrouping.portKey(forLocationID: 0x14200000), 0x142, "不同根端口键不同")
        XCTAssertEqual(PortGrouping.portKey(forLocationID: 0x02100000), 0x021)
        XCTAssertEqual(PortGrouping.portKey(forLocationID: 0), 0, "registry 未提供 LocationID 时为 0 号兜底桶")
    }

    func testHubDepthCountsDownstreamNibbles() {
        XCTAssertEqual(PortGrouping.hubDepth(forLocationID: 0x14100000), 0, "直插根端口深度 0")
        XCTAssertEqual(PortGrouping.hubDepth(forLocationID: 0x14130000), 1, "经一层 hub 深度 1")
        XCTAssertEqual(PortGrouping.hubDepth(forLocationID: 0x14134000), 2, "经两层 hub 深度 2")
        XCTAssertEqual(PortGrouping.hubDepth(forLocationID: 0), 0)
    }

    // MARK: - USB 会话聚合

    private func makeUSBDevice(registryID: UInt64, locationID: UInt32, name: String?, bps: Int?,
                               physicalPortID: String? = nil) -> USBDeviceSnapshot {
        USBDeviceSnapshot(
            registryID: registryID,
            locationID: locationID,
            physicalPortID: physicalPortID,
            productName: name,
            vendorName: nil,
            vendorID: nil,
            productID: nil,
            serialNumber: nil,
            bcdUSB: nil,
            speed: bps.map { USBSpeed(bitsPerSecond: $0) }
        )
    }

    func testBuildSessionsGroupsUSBByRootPort() {
        let hub = makeUSBDevice(registryID: 1, locationID: 0x14100000, name: "Hub", bps: 480_000_000)
        let ssd = makeUSBDevice(registryID: 2, locationID: 0x14130000, name: "SSD", bps: 10_000_000_000)
        let other = makeUSBDevice(registryID: 3, locationID: 0x14200000, name: "Other", bps: 1_500_000)

        let sessions = PortGrouping.buildSessions(usbDevices: [hub, ssd, other], thunderboltDevices: [])

        XCTAssertEqual(sessions.map(\.id), ["usb-0x141", "usb-0x142"], "按端口键排序")
        XCTAssertEqual(sessions[0].usbDevices.map(\.productName), ["Hub", "SSD"], "会话内按 locationID 排序，天然呈 hub 链路顺序")
        XCTAssertEqual(sessions[0].portLabel, "USB 端口 0x141")
        XCTAssertEqual(sessions[0].topUSBSpeed?.bitsPerSecond, 10_000_000_000, "会话速率取成员峰值")
        XCTAssertEqual(sessions[0].deviceCount, 2)
        XCTAssertEqual(sessions[0].shortPortLabel, "USB·0x141")
    }

    func testBuildSessionsPutsUnknownLocationBucketLast() {
        let normal = makeUSBDevice(registryID: 1, locationID: 0x14100000, name: "A", bps: nil)
        let unknown = makeUSBDevice(registryID: 2, locationID: 0, name: "B", bps: nil)

        let sessions = PortGrouping.buildSessions(usbDevices: [unknown, normal], thunderboltDevices: [])

        XCTAssertEqual(sessions.map(\.id), ["usb-0x141", "usb-0x000"])
        XCTAssertEqual(sessions[1].portLabel, "USB 端口（未知）")
        XCTAssertEqual(sessions[1].shortPortLabel, "USB·?")
    }

    // MARK: - 端口控制器会话（AppleHPM 活跃端口一等成卡）

    private func makePort(portID: String,
                          portType: String? = "USB-C",
                          isActive: Bool = true,
                          winning: PDOPhase? = nil) -> USBCPortSnapshot {
        USBCPortSnapshot(
            portID: portID,
            controllerClass: "AppleHPMInterfaceType10",
            portType: portType,
            plugOrientation: nil,
            isActive: isActive,
            hasActiveCable: false,
            connectionCount: nil,
            transportsSupported: ["CC"],
            transportsProvisioned: ["CC"],
            featuresEnabled: [],
            eMarker: nil,
            partner: nil,
            powerSource: winning.map { PDOPortPowerSnapshot(sourceName: "USB-PD", options: [$0], winning: $0) }
        )
    }

    private func makeWinning100W() -> PDOPhase {
        PDOPhase(voltageMV: 20_000, maxCurrentMA: 5_000, maxPowerMW: 100_000, uuid: "test")
    }

    private func makePowerSnapshot(externalConnected: Bool) -> PowerSnapshot {
        PowerSnapshot(isCharging: externalConnected,
                      batteryPercent: 80,
                      adapterVoltageMV: 20_000,
                      adapterAmperageMA: 5_000,
                      pdContract: PDContract(voltageMV: 20_000, currentMA: 5_000),
                      adapterDescription: nil,
                      cycleCount: nil,
                      externalConnected: externalConnected)
    }

    /// 纯 PD 充电不枚举任何 USB 设备：活跃端口成卡是充电线可见的唯一途径（真机回归场景）
    func testActiveChargingPortBecomesSessionWithoutDevices() {
        let charger = makePort(portID: "Port-USB-C@2", winning: makeWinning100W())

        let sessions = PortGrouping.buildSessions(usbDevices: [], thunderboltDevices: [], ports: [charger])

        XCTAssertEqual(sessions.map(\.id), ["Port-USB-C@2"])
        XCTAssertEqual(sessions[0].portLabel, "USB-C 端口 @2")
        XCTAssertEqual(sessions[0].shortPortLabel, "USB-C·@2")
        XCTAssertEqual(sessions[0].physicalPortID, "Port-USB-C@2")
        XCTAssertTrue(sessions[0].usbDevices.isEmpty, "充电线没有数据设备，会话允许为空")
    }

    func testInactivePortWithoutDevicesHasNoSession() {
        let idle = makePort(portID: "Port-USB-C@2", isActive: false)
        XCTAssertTrue(PortGrouping.buildSessions(usbDevices: [], thunderboltDevices: [], ports: [idle]).isEmpty,
                      "未接线的空端口不成卡（空端口列表是 v2 待办）")
    }

    func testUSBDevicesMergeIntoPortSessionAndKeepLegacyID() {
        // 有 LocationID 的设备桶挂进端口会话时沿用旧会话 id，评级历史不断档
        let hub = makeUSBDevice(registryID: 1, locationID: 0x14100000, name: "Hub", bps: 480_000_000,
                                physicalPortID: "Port-USB-C@1")
        let monitor = makePort(portID: "Port-USB-C@1")

        let sessions = PortGrouping.buildSessions(usbDevices: [hub], thunderboltDevices: [], ports: [monitor])

        XCTAssertEqual(sessions.map(\.id), ["usb-0x141"])
        XCTAssertEqual(sessions[0].usbDevices.map(\.productName), ["Hub"])
        XCTAssertEqual(sessions[0].physicalPortID, "Port-USB-C@1")
    }

    /// 真机案例：显示器内置 hub 无 LocationID（portKey 0 未知桶），但 UsbIOPort 能配到端口
    func testLocationlessDevicesMergeIntoPortSessionWithPortNodeID() {
        let hub = makeUSBDevice(registryID: 1, locationID: 0, name: "USB2.1 Hub", bps: nil,
                                physicalPortID: "Port-USB-C@1")
        let monitor = makePort(portID: "Port-USB-C@1")

        let sessions = PortGrouping.buildSessions(usbDevices: [hub], thunderboltDevices: [], ports: [monitor])

        XCTAssertEqual(sessions.map(\.id), ["Port-USB-C@1"],
                       "未知端口桶不再吞掉可配对设备，改用端口节点 id")
        XCTAssertEqual(sessions[0].usbDevices.map(\.productName), ["USB2.1 Hub"])
    }

    func testUnmatchedUSBDevicesFallBackToOwnSessionAfterPortSessions() {
        let device = makeUSBDevice(registryID: 1, locationID: 0x14100000, name: "A", bps: nil)
        let port = makePort(portID: "Port-USB-C@1")

        let sessions = PortGrouping.buildSessions(usbDevices: [device], thunderboltDevices: [], ports: [port])

        XCTAssertEqual(sessions.map(\.id), ["Port-USB-C@1", "usb-0x141"],
                       "配不上端口的设备保持独立会话，排在端口会话之后")
    }

    // MARK: - 电源归属（多线时按 winning 端口归属，宁缺毋滥）

    func testAttributablePowerGoesToSingleWinningPortSession() {
        let displayPort = makePort(portID: "Port-USB-C@1")
        let chargerPort = makePort(portID: "Port-USB-C@2", winning: makeWinning100W())
        let ports = [displayPort, chargerPort]
        let sessions = PortGrouping.buildSessions(usbDevices: [], thunderboltDevices: [], ports: ports)
        XCTAssertEqual(sessions.count, 2)

        let owner = PortGrouping.attributablePowerSessionID(
            sessions: sessions, ports: ports, power: makePowerSnapshot(externalConnected: true))

        XCTAssertEqual(owner, "Port-USB-C@2", "恰有一个在收电的端口时，整机电源归属充电线")
    }

    func testAttributablePowerIsNilWhenTwoPortsNegotiate() {
        // 充电器 + 供电坞站同时有协商合同：无法分辨整机读数来自哪根线
        let chargerPort = makePort(portID: "Port-USB-C@2", winning: makeWinning100W())
        let dockPort = makePort(portID: "Port-USB-C@3", winning: makeWinning100W())
        let ports = [chargerPort, dockPort]
        let sessions = PortGrouping.buildSessions(usbDevices: [], thunderboltDevices: [], ports: ports)

        XCTAssertNil(PortGrouping.attributablePowerSessionID(
            sessions: sessions, ports: ports, power: makePowerSnapshot(externalConnected: true)))
    }

    func testAttributablePowerKeepsSingleSessionRule() {
        let port = makePort(portID: "Port-USB-C@1")
        let sessions = PortGrouping.buildSessions(usbDevices: [], thunderboltDevices: [], ports: [port])

        XCTAssertEqual(
            PortGrouping.attributablePowerSessionID(sessions: sessions, ports: [port], power: nil),
            "Port-USB-C@1",
            "单会话规则与 v1 一致（不依赖电源/端口数据）")
    }

    // MARK: - 端口节点标签

    func testPortTypeNameStripsPrefixAndLocation() {
        XCTAssertEqual(PortGrouping.portTypeName(fromPortID: "Port-USB-C@1"), "USB-C")
        XCTAssertEqual(PortGrouping.portTypeName(fromPortID: "Port-MagSafe 3@1"), "MagSafe 3")
        XCTAssertEqual(PortGrouping.portTypeName(fromPortID: "Port-USB-C"), "USB-C")
    }

    func testPortLabelUsesPortTypeDescription() {
        XCTAssertEqual(PortGrouping.portLabel(for: makePort(portID: "Port-USB-C@1")), "USB-C 端口 @1")
        XCTAssertEqual(PortGrouping.portLabel(for: makePort(portID: "Port-MagSafe 3@1", portType: "MagSafe 3")),
                       "MagSafe 3 端口 @1")
        XCTAssertEqual(PortGrouping.portLabel(for: makePort(portID: "Port-USB-C", portType: nil)), "USB-C 端口")
    }

    // MARK: - 雷雳会话聚合

    private func makeTBDevice(name: String, receptaclePort: Int?) -> ThunderboltDeviceSnapshot {
        ThunderboltDeviceSnapshot(name: name, vendorName: nil, linkSpeedLabel: nil,
                                  deviceType: nil, receptaclePort: receptaclePort)
    }

    func testBuildThunderboltSessionsByReceptacle() {
        let dock = makeTBDevice(name: "Dock", receptaclePort: 1)
        let monitor = makeTBDevice(name: "LG", receptaclePort: 1) // 级联在同一个 receptacle 下
        let ssd = makeTBDevice(name: "SSD", receptaclePort: 3)
        let orphan = makeTBDevice(name: "Mystery", receptaclePort: nil) // 旧数据/解析失败的兜底

        let sessions = PortGrouping.buildSessions(usbDevices: [], thunderboltDevices: [dock, monitor, ssd, orphan])

        XCTAssertEqual(sessions.map(\.id), ["tb-1", "tb-3", "tb-0"], "USB 会话在前，未知端口桶垫底")
        XCTAssertEqual(sessions[0].thunderboltDevices.map(\.name), ["Dock", "LG"])
        XCTAssertEqual(sessions[0].portLabel, "雷雳端口 1")
        XCTAssertEqual(sessions[0].shortPortLabel, "雷雳·1")
        XCTAssertEqual(sessions[2].portLabel, "雷雳端口（未知）")
        XCTAssertEqual(sessions[2].shortPortLabel, "雷雳·?")
    }

    func testUSBSessionsComeBeforeThunderboltSessions() {
        let usb = makeUSBDevice(registryID: 1, locationID: 0x14100000, name: "A", bps: nil)
        let tb = makeTBDevice(name: "Dock", receptaclePort: 1)

        let sessions = PortGrouping.buildSessions(usbDevices: [usb], thunderboltDevices: [tb])

        XCTAssertEqual(sessions.map(\.kind), [.usb, .thunderbolt])
    }

    // MARK: - 外接显示器归属（DisplayPort 传输节点直读）

    /// 真机数值（本机验证）：AOC U27U3XD，vendorNumber=1507 解码为 "AOC"，modelNumber=9987。
    private func makeExternalDisplay(displayID: UInt32 = 2, modelNumber: UInt32? = 9987,
                                     vendorNumber: UInt32? = 1507, isBuiltin: Bool = false) -> DisplaySnapshot {
        DisplaySnapshot(displayID: displayID, name: "U27U3XD", pixelWidth: 3840, pixelHeight: 2160,
                       refreshRateHz: 144, linkRateLabel: nil, isMain: false, isBuiltin: isBuiltin,
                       vendorNumber: vendorNumber, modelNumber: modelNumber, serialNumber: 393)
    }

    private func makeDisplayLink(portID: String? = "Port-USB-C@1", productID: UInt32? = 9987,
                                 manufacturerName: String? = "AOC") -> DisplayPortLinkSnapshot {
        DisplayPortLinkSnapshot(portID: portID, isActive: true, isTunneled: false,
                                linkRateDescription: "8.1 Gbps (HBR3)", manufacturerName: manufacturerName,
                                productName: "U27U3XD", productID: productID, serialNumber: 393)
    }

    func testDisplayPortLinksMatchByPhysicalPortID() {
        let port = makePort(portID: "Port-USB-C@1")
        let sessions = PortGrouping.buildSessions(usbDevices: [], thunderboltDevices: [], ports: [port])
        let link = makeDisplayLink(portID: "Port-USB-C@1")
        let otherLink = makeDisplayLink(portID: "Port-USB-C@2")

        let matched = PortGrouping.displayPortLinks(for: sessions[0], links: [link, otherLink])

        XCTAssertEqual(matched.map(\.portID), ["Port-USB-C@1"], "只匹配 physicalPortID 相同的链路")
    }

    func testDisplayPortLinksEmptyWhenSessionHasNoPhysicalPortID() {
        let device = makeUSBDevice(registryID: 1, locationID: 0x14100000, name: "A", bps: nil)
        let sessions = PortGrouping.buildSessions(usbDevices: [device], thunderboltDevices: [])
        XCTAssertTrue(PortGrouping.displayPortLinks(for: sessions[0], links: [makeDisplayLink()]).isEmpty,
                     "无 physicalPortID 的会话（雷雳/未配对 USB）恒不归属显示器链路")
    }

    func testMatchedDisplayByProductIDAndVendorPNPCode() {
        let matched = PortGrouping.matchedDisplay(for: makeDisplayLink(), in: [makeExternalDisplay()])
        XCTAssertEqual(matched?.displayID, 2, "Product ID 与厂商 PNP 码都对得上时精确匹配")
    }

    func testMatchedDisplayIsNilWhenProductIDDiffers() {
        let display = makeExternalDisplay(modelNumber: 1234)
        XCTAssertNil(PortGrouping.matchedDisplay(for: makeDisplayLink(), in: [display]))
    }

    func testMatchedDisplayIsNilWhenVendorMismatches() {
        // Product ID 相同但厂商对不上：可能是撞了型号号段的另一款显示器，不瞎连。
        let display = makeExternalDisplay(vendorNumber: 9999)
        XCTAssertNil(PortGrouping.matchedDisplay(for: makeDisplayLink(), in: [display]))
    }

    func testMatchedDisplayIsNilWhenAmbiguous() {
        // 两台同型号显示器：命中不唯一，宁可不归属也不归错。
        let a = makeExternalDisplay(displayID: 2)
        let b = makeExternalDisplay(displayID: 3)
        XCTAssertNil(PortGrouping.matchedDisplay(for: makeDisplayLink(), in: [a, b]))
    }

    func testMatchedDisplayExcludesBuiltinPanel() {
        // 内置屏理论上也可能凑巧共享同一 Product ID（极端边界）：DisplayPort 链路永远是外接的。
        let builtin = makeExternalDisplay(isBuiltin: true)
        XCTAssertNil(PortGrouping.matchedDisplay(for: makeDisplayLink(), in: [builtin]))
    }

    func testMatchedDisplayIsNilWhenLinkHasNoProductID() {
        let link = makeDisplayLink(productID: nil)
        XCTAssertNil(PortGrouping.matchedDisplay(for: link, in: [makeExternalDisplay()]))
    }

    func testPNPCodeDecodesRealVendorNumber() {
        XCTAssertEqual(PortGrouping.pnpCode(fromPackedVendor: 1507), "AOC", "本机真实 CGDisplayVendorNumber 解码")
        XCTAssertNil(PortGrouping.pnpCode(fromPackedVendor: 0xFFFF), "解不出合法字母时返回 nil，不误判")
    }

    // MARK: - JSON 兼容（旧数据升级）

    func testOldSnapshotJSONWithoutSessionsDecodesEmptySessions() throws {
        // 旧版 JSON（无 sessions 字段）应解码为空数组，由消费方按需用 PortGrouping 现算
        let json = """
        {
          "id": "DEADBEEF-1234-5678-9ABC-DEF012345678",
          "timestamp": "2026-09-13T08:00:00Z",
          "usbDevices": [],
          "displays": [],
          "thunderboltDevices": []
        }
        """
        let snapshot = try CableSnapshot.fromJSON(Data(json.utf8))
        XCTAssertTrue(snapshot.sessions.isEmpty)
        XCTAssertNil(snapshot.power)
    }

    func testOldSnapshotJSONWithoutDisplayPortLinksDecodesEmpty() throws {
        let json = """
        {
          "id": "DEADBEEF-1234-5678-9ABC-DEF012345678",
          "timestamp": "2026-09-13T08:00:00Z",
          "usbDevices": [],
          "displays": [],
          "thunderboltDevices": []
        }
        """
        let snapshot = try CableSnapshot.fromJSON(Data(json.utf8))
        XCTAssertTrue(snapshot.displayPortLinks.isEmpty, "旧 JSON 无 displayPortLinks 键时应解码为空数组")
    }

    func testOldDisplayJSONWithoutEDIDFieldsDecodesNilAndFalse() throws {
        let json = #"""
        {"displayID":1,"name":"Color LCD","pixelWidth":2940,"pixelHeight":1912,
         "refreshRateHz":60.0,"linkRateLabel":null,"isMain":true}
        """#
        let display = try JSONDecoder().decode(DisplaySnapshot.self, from: Data(json.utf8))
        XCTAssertFalse(display.isBuiltin, "旧 JSON 无 isBuiltin 键时应解码为 false（未知即不当内置屏参与匹配）")
        XCTAssertNil(display.vendorNumber)
        XCTAssertNil(display.modelNumber)
        XCTAssertNil(display.serialNumber)
    }

    func testOldThunderboltJSONWithoutReceptaclePortDecodesNil() throws {
        let json = #"{"name":"Dock","vendorName":"CalDigit","linkSpeedLabel":"Up to 40 Gb/s","deviceType":"Peripherals"}"#
        let device = try JSONDecoder().decode(ThunderboltDeviceSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(device.name, "Dock")
        XCTAssertNil(device.receptaclePort, "旧 JSON 无 receptaclePort 键时应解码为 nil")
    }

    func testSnapshotJSONRoundTripWithSessions() throws {
        let device = makeUSBDevice(registryID: 1, locationID: 0x14100000, name: "SSD", bps: 10_000_000_000)
        let session = CableSession(
            id: "usb-0x141",
            kind: .usb,
            portKey: 0x141,
            portLabel: "USB 端口 0x141",
            usbDevices: [device]
        )
        let snapshot = CableSnapshot(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            usbDevices: [device],
            power: nil,
            displays: [],
            thunderboltDevices: [],
            sessions: [session]
        )

        let decoded = try CableSnapshot.fromJSON(snapshot.toJSON())

        XCTAssertEqual(decoded, snapshot, "含 sessions 的快照应无损往返")
        XCTAssertEqual(decoded.sessions.first?.shortPortLabel, "USB·0x141")
    }
}
