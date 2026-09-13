@testable import CableKit
import XCTest

/// IORegistryValue 的 CF 类型分派、渲染与 JSON 平铺编码测试。
final class IORegistryValueTests: XCTestCase {
    // MARK: - CF 类型分派

    func testScalarConversion() {
        // Swift 值类型经桥接后 CFTypeID 必须分派到正确 case（尤其 Bool 与 Int）。
        XCTAssertEqual(IORegistryValue(anyValue: "pd charger"), .string("pd charger"))
        XCTAssertEqual(IORegistryValue(anyValue: 20_000), .number(20_000))
        XCTAssertEqual(IORegistryValue(anyValue: NSNumber(value: Int64.max)), .number(Int64.max))
        XCTAssertEqual(IORegistryValue(anyValue: true), .boolean(true))
        XCTAssertEqual(IORegistryValue(anyValue: false), .boolean(false))
        XCTAssertEqual(IORegistryValue(anyValue: 20.5), .double(20.5))
    }

    func testBoolAndNumberAreDistinguished() {
        // NSNumber 桥接会同时成功 cast 到 Bool/Int，必须按 CFTypeID 区分。
        guard case .boolean(let boolValue) = IORegistryValue(anyValue: true) else {
            return XCTFail("true 应转换为 boolean")
        }
        XCTAssertTrue(boolValue)
        guard case .number(let intValue) = IORegistryValue(anyValue: 1) else {
            return XCTFail("1 应转换为 number 而不是 boolean")
        }
        XCTAssertEqual(intValue, 1)
    }

    func testNestedConversion() {
        let nested: [String: Any] = [
            "Description": "pd charger",
            "AdapterVoltage": 20_000,
            "UsbHvcMenu": [[ "Index": 0, "MaxVoltage": 5_000 ] as [String: Any]],
            "IsWireless": false,
        ]
        guard case .dictionary(let dict) = IORegistryValue(anyValue: nested) else {
            return XCTFail("字典应转换为 dictionary")
        }
        XCTAssertEqual(dict["Description"], .string("pd charger"))
        XCTAssertEqual(dict["AdapterVoltage"], .number(20_000))
        XCTAssertEqual(dict["IsWireless"], .boolean(false))
        guard case .array(let items)? = dict["UsbHvcMenu"], items.count == 1 else {
            return XCTFail("嵌套数组应转换为 array")
        }
        XCTAssertEqual(items[0],
                       .dictionary(["Index": .number(0), "MaxVoltage": .number(5_000)]))
    }

    func testDataConversion() {
        let payload = Data([0x00, 0xFF, 0x10])
        XCTAssertEqual(IORegistryValue(anyValue: payload), .data(payload))
    }

    // MARK: - 渲染

    func testDisplayText() {
        XCTAssertEqual(IORegistryValue.string("abc").displayText, "abc")
        XCTAssertEqual(IORegistryValue.number(20_000).displayText, "20000")
        XCTAssertEqual(IORegistryValue.boolean(true).displayText, "Yes")
        XCTAssertEqual(IORegistryValue.boolean(false).displayText, "No")
        XCTAssertEqual(IORegistryValue.double(20.5).displayText, "20.5")
        XCTAssertEqual(IORegistryValue.double(20.0).displayText, "20")
        XCTAssertEqual(IORegistryValue.array([.string("a"), .number(1)]).displayText, "[a, 1]")
        XCTAssertEqual(IORegistryValue.dictionary(["k": .boolean(true)]).displayText, "{k=Yes}")
    }

    func testDataHexRendering() {
        XCTAssertEqual(Data([0x1a, 0x2b]).displayAsHex(limit: 64), "0x1a 0x2b")
        let bytes = Data((0..<80).map { UInt8($0) })
        let rendered = bytes.displayAsHex(limit: 64)
        XCTAssertTrue(rendered.contains("(80 bytes)"), "超长 Data 应标注总字节数：\(rendered)")
        XCTAssertTrue(rendered.hasPrefix("0x00 0x01"))
        XCTAssertEqual(Data().displayAsHex(limit: 64), "<empty data>")
    }

    // MARK: - JSON 平铺编码

    func testFlatJSONEncoding() throws {
        let value = IORegistryValue.dictionary([
            "Name": .string("pd charger"),
            "Voltage": .number(20_000),
            "Wireless": .boolean(false),
        ])
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any]
        XCTAssertEqual(object?["Name"] as? String, "pd charger")
        XCTAssertEqual(object?["Voltage"] as? Int, 20_000)
        XCTAssertEqual(object?["Wireless"] as? Bool, false)
    }

    func testJSONRoundTripScalars() throws {
        let original: [String: IORegistryValue] = [
            "s": .string("abc"),
            "n": .number(-7),
            "d": .double(20.5),
            "b": .boolean(true),
            "a": .array([.number(1), .string("x")]),
            "dict": .dictionary(["k": .number(2)]),
        ]
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode([String: IORegistryValue].self, from: data)
        XCTAssertEqual(decoded, original, "标量/数组/字典应无损回环")
    }

    func testJSONRoundTripDegradesGracefully() throws {
        // JSON 无法表达 Data/Date：编码为字符串，解码为 .string（见类型文档的保真边界）。
        let original = IORegistryValue.dictionary([
            "edid": .data(Data([0xAA])),
            "when": .date(Date(timeIntervalSince1970: 0)),
        ])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(IORegistryValue.self, from: data)
        guard case .dictionary(let dict) = decoded else {
            return XCTFail("应解码为 dictionary")
        }
        XCTAssertEqual(dict["edid"], .string(Data([0xAA]).base64EncodedString()))
        XCTAssertEqual(dict["when"], .string("1970-01-01T00:00:00Z"))
    }

    // MARK: - RegistryText 渲染

    func testRegistryTextRendersSortedAndIndented() {
        let props: [String: IORegistryValue] = [
            "B": .number(2),
            "A": .string("first"),
            "Nested": .dictionary(["Y": .boolean(true), "X": .number(1)]),
            "List": .array([.string("i0"), .string("i1")]),
            "Empty": .dictionary([:]),
        ]
        let lines = RegistryText.render(props)
        XCTAssertEqual(lines, [
            "A: first",
            "B: 2",
            "Empty: {}",
            "List:",
            "  - i0",
            "  - i1",
            "Nested:",
            "  X: 1",
            "  Y: Yes",
        ])
    }

    // MARK: - 快照解码兼容

    func testUSBDeviceSnapshotDecodingWithoutRawProperties() throws {
        // 旧版本 JSON 没有 rawProperties 键：解码应成功且视为空字典。
        let legacy = """
        {"registryID":42,"locationID":263192576}
        """
        let device = try JSONDecoder().decode(USBDeviceSnapshot.self, from: Data(legacy.utf8))
        XCTAssertEqual(device.registryID, 42)
        XCTAssertTrue(device.rawProperties.isEmpty)
    }

    func testUSBDeviceSnapshotJSONRoundTrip() throws {
        let device = USBDeviceSnapshot(
            registryID: 7, locationID: 0x14100000, productName: "Hub",
            vendorName: nil, vendorID: 0x05AC, productID: 0x2082,
            serialNumber: nil, bcdUSB: "0210",
            speed: USBSpeed(bitsPerSecond: 480_000_000),
            rawProperties: ["Speed": .number(480_000_000), "Tag": .data(Data([0x01]))]
        )
        let data = try JSONEncoder().encode(device)
        let decoded = try JSONDecoder().decode(USBDeviceSnapshot.self, from: data)
        XCTAssertEqual(decoded.rawProperties["Speed"], .number(480_000_000))
    }
}
