import XCTest
@testable import CableKit

/// PortControllerService 的 IORegistry 属性解析测试。
/// 样例结构来自真机 `ioreg -r -c AppleHPMInterfaceType10`（MacBook Pro 14, macOS 26）。
final class PortParsingTests: XCTestCase {

    // MARK: 端口节点

    func testParsePortWithRealShapedProperties() {
        let props: [String: Any] = [
            "PortTypeDescription": "USB-C",
            "ActiveCable": false,
            "ConnectionActive": true,
            "ConnectionCount": 10,
            "PlugOrientation": 1,
            "TransportsSupported": ["CC", "USB2", "USB3", "CIO", "DisplayPort"],
            "TransportsProvisioned": ["CC", "USB2", "DisplayPort"],
            "FeaturesEnabled": ["TRM", "LDCM", "Power In"],
        ]
        let port = PortParsing.parsePort(portID: "Port-USB-C@1",
                                         controllerClass: "AppleHPMInterfaceType10",
                                         properties: props,
                                         partnerProperties: nil,
                                         eMarkerProperties: nil,
                                         powerSourceProperties: nil)

        XCTAssertEqual(port.portID, "Port-USB-C@1")
        XCTAssertEqual(port.portType, "USB-C")
        XCTAssertTrue(port.isActive)
        XCTAssertFalse(port.hasActiveCable)
        XCTAssertEqual(port.plugOrientation, 1)
        XCTAssertEqual(port.connectionCount, 10)
        XCTAssertTrue(port.supportsThunderboltUSB4, "TransportsSupported 含 CIO ⇒ USB4/雷雳可用")
        XCTAssertEqual(port.transportsProvisioned, ["CC", "USB2", "DisplayPort"])
        XCTAssertNil(port.eMarker)
        XCTAssertNil(port.partner)
        XCTAssertNil(port.powerSource)
    }

    func testParsePortWithoutCIOIsNotThunderboltCapable() {
        let props: [String: Any] = [
            "PortTypeDescription": "MagSafe 3",
            "TransportsSupported": ["CC"],
        ]
        let port = PortParsing.parsePort(portID: "Port-MagSafe 3@1",
                                         controllerClass: "AppleHPMInterfaceType11",
                                         properties: props,
                                         partnerProperties: nil,
                                         eMarkerProperties: nil,
                                         powerSourceProperties: nil)
        XCTAssertFalse(port.supportsThunderboltUSB4)
        XCTAssertEqual(port.portType, "MagSafe 3")
    }

    // MARK: SOP' e-marker（真机 VDO：被动线缆，未上报 VID）

    func testParseEMarkerFromRealCableVDOs() {
        // 真机样例：VDOs = (<00000018>, <00000000>, <00000000>, <42400800>)，线上小端。
        let props: [String: Any] = [
            "Product Type": 3,
            "Product Type Description": "Passive Cable",
            "Vendor ID": 0,
            "Product ID": 0,
            "Metadata": [
                "VDOs": [
                    vdoData(0x18),          // ID Header（大端字节序的原始线上数据）
                    vdoData(0),
                    vdoData(0),
                    vdoData(0x42400800),    // Cable VDO
                ],
            ],
        ]
        let eMarker = PortParsing.parseEMarker(props)

        XCTAssertNotNil(eMarker)
        XCTAssertEqual(eMarker?.vendorID, 0, "未上报厂商 ID（0）也要如实保留")
        XCTAssertEqual(eMarker?.productType, 3)
        XCTAssertEqual(eMarker?.productTypeDescription, "Passive Cable")
        XCTAssertEqual(eMarker?.decodedProductType, 3, "ID Header VDO 小端解读 ⇒ Product Type 3（被动线缆）")
        XCTAssertEqual(eMarker?.decodedSpeed, .usb32Gen2, "Cable VDO bits[2:0]=010 ⇒ USB 3.2 Gen2")
        XCTAssertEqual(eMarker?.decodedCurrentRating, .fiveAmp, "Cable VDO bits[6:5]=10 ⇒ 5A")
    }

    func testParseEMarkerWithOnlyTopLevelFields() {
        // 部分线缆只在顶层平铺身份字段，Metadata 缺失也应可解析。
        let props: [String: Any] = [
            "Product Type Description": "Active Cable",
            "Vendor ID": 0x0BDA,
        ]
        let eMarker = PortParsing.parseEMarker(props)
        XCTAssertEqual(eMarker?.productTypeDescription, "Active Cable")
        XCTAssertEqual(eMarker?.vendorID, 0x0BDA)
        XCTAssertNil(eMarker?.decodedSpeed, "无 VDO 时不猜测速度")
    }

    func testParseEMarkerEmptyNodeReturnsNil() {
        XCTAssertNil(PortParsing.parseEMarker([:]))
        XCTAssertNil(PortParsing.parseEMarker(["Metadata": [:]]))
    }

    // MARK: SOP 对端身份

    func testParsePartnerIdentity() {
        let props: [String: Any] = [
            "Vendor ID": 3034, // 0x0BDA Realtek
            "Product ID": 0,
            "Metadata": [
                "VDOs": [vdoData(0x54400BDA), vdoData(0), vdoData(5), vdoData(0x44800191)],
                "Vendor ID": 3034,
            ],
        ]
        let partner = PortParsing.parsePartner(props)
        XCTAssertEqual(partner?.vendorID, 3034)
        XCTAssertEqual(partner?.vdos.count, 4)
    }

    func testParsePartnerEmptyReturnsNil() {
        XCTAssertNil(PortParsing.parsePartner(["Metadata": [:]]))
    }

    // MARK: PD 档位（PowerSourceOptions 实测为无序 Set）

    func testParsePowerSourceWithSetOptionsAndWinning() {
        // 真机实测 PowerSourceOptions 是无序 NSSet（__NSCFSet）；用乱序数组模拟其无序性。
        let options: [[String: Any]] = [
            phaseDict(voltage: 20000, current: 5000, power: 100000, uuid: "B"),
            phaseDict(voltage: 5000, current: 3000, power: 15000, uuid: "A"),
            phaseDict(voltage: 9000, current: 3000, power: 27000, uuid: "C"),
        ]
        let props: [String: Any] = [
            "PowerSourceName": "USB-PD",
            "PowerSourceOptions": NSSet(array: options.map { NSDictionary(dictionary: $0) }),
            "WinningPowerSourceOption": phaseDict(voltage: 20000, current: 5000, power: 100000, uuid: "B"),
        ]
        let pdo = PortParsing.parsePowerSource(props)

        XCTAssertNotNil(pdo)
        XCTAssertEqual(pdo?.sourceName, "USB-PD")
        XCTAssertEqual(pdo?.options.count, 3)
        XCTAssertEqual(pdo?.options.map(\.voltageMV), [5000, 9000, 20000], "无序 Set 输入也要按电压升序稳定输出")
        XCTAssertEqual(pdo?.winning?.watts ?? 0, 100, accuracy: 0.01)
        XCTAssertEqual(pdo?.winningIndex, 2, "按 UUID 匹配到 20V 档")
    }

    func testParsePowerSourceWinningFallbackByVoltageCurrent() {
        // Winning 与档位 UUID 不一致时按电压+电流兜底匹配。
        let props: [String: Any] = [
            "PowerSourceName": "USB-PD",
            "PowerSourceOptions": [
                phaseDict(voltage: 5000, current: 3000, power: 15000, uuid: "A"),
                phaseDict(voltage: 20000, current: 5000, power: 100000, uuid: "B"),
            ],
            "WinningPowerSourceOption": phaseDict(voltage: 20000, current: 5000, power: 100000, uuid: "OTHER"),
        ]
        let pdo = PortParsing.parsePowerSource(props)
        XCTAssertEqual(pdo?.winningIndex, 1)
    }

    func testParsePowerSourceEmptyNodeReturnsNil() {
        XCTAssertNil(PortParsing.parsePowerSource(["PowerSourceName": "TypeC"]))
    }

    // MARK: UsbIOPort 路径解析

    func testPortIDFromUsbIOPortPath() {
        let path = "IOService:/AppleARMPE/arm-io@10F00000/AppleH16GFamilyIO/nub-spmi-a0@88908000/"
            + "AppleSPMIController/hpm0@C/AppleHPMARMSPMI/AppleHPMDeviceHALType3@C/Port-USB-C@1"
        XCTAssertEqual(PortParsing.portID(fromUsbIOPortPath: path), "Port-USB-C@1")
    }

    func testPortIDRejectsNonPortPath() {
        XCTAssertNil(PortParsing.portID(fromUsbIOPortPath: "IOService:/AppleARMPE/arm-io@10F00000"))
    }

    // MARK: 辅助

    private func phaseDict(voltage: Int, current: Int, power: Int, uuid: String) -> [String: Any] {
        ["Voltage (mV)": voltage, "Max Current (mA)": current, "Max Power (mW)": power, "UUID": uuid]
    }

    /// 模拟 ioreg/CFProperties 里 Data 的原始字节（数字按大端写成字节序列）。
    private func vdoData(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }
}
