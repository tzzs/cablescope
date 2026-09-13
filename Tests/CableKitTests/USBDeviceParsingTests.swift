import XCTest
@testable import CableKit

/// USBService 的 IORegistry 属性解析测试（键名/类型变体均来自真机实测）。
final class USBDeviceParsingTests: XCTestCase {
    func testParseFullProperties() {
        let props: [String: Any] = [
            "Speed": 480_000_000,
            "LocationID": 0x14100000,
            "USB Product Name": "USB3.0 Hub",
            "USB Vendor Name": "Generic",
            "idVendor": 1452,
            "idProduct": 8326,
            "USB Serial Number": "SER123",
            "bcdUSB": "0210",
        ]
        let device = USBDeviceParsing.parse(properties: props, registryID: 42)

        XCTAssertEqual(device.registryID, 42)
        XCTAssertEqual(device.locationID, 0x14100000)
        XCTAssertEqual(device.productName, "USB3.0 Hub")
        XCTAssertEqual(device.vendorName, "Generic")
        XCTAssertEqual(device.vendorID, 1452)
        XCTAssertEqual(device.productID, 8326)
        XCTAssertEqual(device.serialNumber, "SER123")
        XCTAssertEqual(device.bcdUSB, "0210")
        XCTAssertEqual(device.speed?.bitsPerSecond, 480_000_000)
    }

    func testBCDUSBVariants() {
        // 字符串编码
        XCTAssertEqual(USBDeviceParsing.bcdUSBString(in: ["bcdUSB": "0310"]), "0310")
        // 数字编码：0x0210 = 528 → "0210"；0x0200 = 512 → "0200"
        XCTAssertEqual(USBDeviceParsing.bcdUSBString(in: ["bcdUSB": 528]), "0210")
        XCTAssertEqual(USBDeviceParsing.bcdUSBString(in: ["bcdUSB": 512]), "0200")
        // 缺失
        XCTAssertNil(USBDeviceParsing.bcdUSBString(in: [:]))
    }

    func testSpeedNumberTypeVariants() {
        // IORegistry 数值可能是 NSNumber / Int32 / UInt32 等
        XCTAssertEqual(USBDeviceParsing.int64Value(forKey: "Speed", in: ["Speed": 10_000_000_000]), 10_000_000_000)
        XCTAssertEqual(USBDeviceParsing.int64Value(forKey: "Speed", in: ["Speed": NSNumber(value: 5_000_000_000)]), 5_000_000_000)
        XCTAssertNil(USBDeviceParsing.int64Value(forKey: "Speed", in: ["Speed": "fast"]))
        XCTAssertNil(USBDeviceParsing.int64Value(forKey: "Speed", in: [:]))
    }

    func testUint16OverflowReturnsNil() {
        // 超出 UInt16 范围的 ID 应回退为 nil，而不是截断或崩溃
        XCTAssertNil(USBDeviceParsing.uint16Value(forKey: "idVendor", in: ["idVendor": 70_000]))
        XCTAssertNil(USBDeviceParsing.uint16Value(forKey: "idVendor", in: ["idVendor": -1]))
        XCTAssertEqual(USBDeviceParsing.uint16Value(forKey: "idVendor", in: ["idVendor": 0x05AC]), 0x05AC)
    }

    func testMissingOptionalFields() {
        let device = USBDeviceParsing.parse(properties: ["Speed": 480_000_000], registryID: 1)
        XCTAssertEqual(device.locationID, 0, "LocationID 缺失且无路径段时归入 0 号桶")
        XCTAssertNil(device.productName)
        XCTAssertNil(device.vendorID)
        XCTAssertNil(device.serialNumber)
        XCTAssertEqual(device.speed?.bitsPerSecond, 480_000_000)
    }

    // MARK: LocationID 路径回退（内置 hub 无 LocationID 属性的真机场景）

    func testLocationIDFallsBackToPathSegment() {
        let props: [String: Any] = ["USB Product Name": "USB2.1 Hub"]
        let device = USBDeviceParsing.parse(properties: props, registryID: 1,
                                            pathSegment: "USB2.1 Hub@00100000")
        XCTAssertEqual(device.locationID, 0x00100000, "无 LocationID 属性时回退路径末段 @hex")
    }

    func testPropertyLocationIDWinsOverPathSegment() {
        let props: [String: Any] = ["LocationID": 0x14100000]
        let device = USBDeviceParsing.parse(properties: props, registryID: 1,
                                            pathSegment: "HID Device@00160000")
        XCTAssertEqual(device.locationID, 0x14100000, "属性优先于路径回退")
    }

    func testLocationIDPathSegmentParsing() {
        XCTAssertEqual(USBDeviceParsing.locationID(fromPathSegment: "USB2.1 Hub@00100000"), 0x00100000)
        XCTAssertEqual(USBDeviceParsing.locationID(fromPathSegment: "HID Device@00160000"), 0x00160000)
        XCTAssertNil(USBDeviceParsing.locationID(fromPathSegment: "USB2.1 Hub"), "无 @ 段返回 nil")
        XCTAssertNil(USBDeviceParsing.locationID(fromPathSegment: "Device@zzz"), "非法十六进制返回 nil")
        XCTAssertNil(USBDeviceParsing.locationID(fromPathSegment: "Device@"), "空 hex 返回 nil")
    }

    // MARK: 物理端口配对字段

    func testPhysicalPortIDRoundTrip() throws {
        let device = USBDeviceParsing.parse(properties: ["LocationID": 0x160000], registryID: 7,
                                            physicalPortID: "Port-USB-C@1")
        XCTAssertEqual(device.physicalPortID, "Port-USB-C@1")

        // 旧 JSON（无 physicalPortID 键）解码兼容
        let encoder = JSONEncoder()
        let data = try encoder.encode(device)
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var legacyObject = object
        legacyObject.removeValue(forKey: "physicalPortID")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let decoded = try JSONDecoder().decode(USBDeviceSnapshot.self, from: legacyData)
        XCTAssertNil(decoded.physicalPortID, "旧 JSON 缺失 physicalPortID 时解码为 nil")
    }
}
