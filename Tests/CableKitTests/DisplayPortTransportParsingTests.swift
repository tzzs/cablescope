import XCTest
@testable import CableKit

/// DisplayPortTransportService 的 IORegistry 属性解析测试。
/// 样例结构来自真机 `ioreg -c IOPortTransportStateDisplayPort -l -r`
/// （MacBook Pro，macOS 26，外接 AOC U27U3XD via USB-C 转 DisplayPort）。
final class DisplayPortTransportParsingTests: XCTestCase {

    func testParseLinkWithRealShapedProperties() {
        let props: [String: Any] = [
            "TransportDescription": "Port-USB-C@1/DisplayPort",
            "ParentPortType": 2,
            "ParentPortNumber": 1,
            "Active": true,
            "Tunneled": false,
            "LinkRateDescription": "8.1 Gbps (HBR3)",
            "ManufacturerName": "AOC",
            "ProductName": "U27U3XD",
            "ProductID": 9987,
            "SerialNumber": 393,
        ]

        let link = DisplayPortTransportParsing.parseLink(props)

        XCTAssertEqual(link.portID, "Port-USB-C@1", "portID 从 TransportDescription 去掉 /DisplayPort 后缀得到")
        XCTAssertTrue(link.isActive)
        XCTAssertFalse(link.isTunneled)
        XCTAssertEqual(link.linkRateDescription, "8.1 Gbps (HBR3)")
        XCTAssertEqual(link.manufacturerName, "AOC")
        XCTAssertEqual(link.productName, "U27U3XD")
        XCTAssertEqual(link.productID, 9987)
        XCTAssertEqual(link.serialNumber, 393)
    }

    func testParseLinkFallsBackToMetadataDictionary() {
        // 真机也观察到顶层字段缺失、身份信息只在 Metadata 子字典里的情况。
        let props: [String: Any] = [
            "TransportDescription": "Port-USB-C@2/DisplayPort",
            "Active": true,
            "Metadata": [
                "ManufacturerName": "AOC",
                "ProductName": "U27U3XD",
                "ProductID": 9987,
                "SerialNumber": 393,
            ],
        ]

        let link = DisplayPortTransportParsing.parseLink(props)

        XCTAssertEqual(link.manufacturerName, "AOC")
        XCTAssertEqual(link.productName, "U27U3XD")
        XCTAssertEqual(link.productID, 9987)
    }

    func testPortIDIsNilWhenTransportDescriptionIsNotAPortPath() {
        // 原生 HDMI 口等没有对应 AppleHPM 端口节点的情况：不强行编出归属。
        XCTAssertNil(DisplayPortTransportParsing.portID(from: [:]))
        XCTAssertNil(DisplayPortTransportParsing.portID(from: ["TransportDescription": "HDMI/DisplayPort"]))
        XCTAssertNil(DisplayPortTransportParsing.portID(from: ["TransportDescription": "Port-USB-C@1/USB3"]))
    }

    func testEmptyIdentityStringsAreNormalisedToNil() {
        // 真机观察到过 ProductName 上报为空字符串的显示器；空字符串不是名字。
        let props: [String: Any] = [
            "TransportDescription": "Port-USB-C@1/DisplayPort",
            "ManufacturerName": "  ",
            "ProductName": "",
        ]
        let link = DisplayPortTransportParsing.parseLink(props)
        XCTAssertNil(link.manufacturerName)
        XCTAssertNil(link.productName)
    }

    func testActiveAndTunneledDefaultFalseWhenMissing() {
        let link = DisplayPortTransportParsing.parseLink(["TransportDescription": "Port-USB-C@1/DisplayPort"])
        XCTAssertFalse(link.isActive)
        XCTAssertFalse(link.isTunneled)
    }
}
