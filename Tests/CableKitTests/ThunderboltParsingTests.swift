import XCTest
@testable import CableKit

/// ThunderboltService 的 SPThunderboltDataType JSON 解析测试（结构来自真机实测 + 合成外设场景）。
final class ThunderboltParsingTests: XCTestCase {
    func testMissingRootKeyReturnsEmpty() {
        XCTAssertTrue(ThunderboltParsing.parse(root: [:]).isEmpty)
        XCTAssertTrue(ThunderboltParsing.parse(root: ["SPThunderboltDataType": "not-an-array"] as [String: Any]).isEmpty)
    }

    func testBusWithoutReceptaclesReturnsEmpty() {
        let root: [String: Any] = [
            "SPThunderboltDataType": [
                ["_name": "thunderboltusb4_bus_1", "device_name_key": "MacBook Air"],
            ],
        ]
        XCTAssertTrue(ThunderboltParsing.parse(root: root).isEmpty, "本机主控不算外接设备")
    }

    func testEmptyReceptacleSkipped() {
        let root: [String: Any] = [
            "SPThunderboltDataType": [
                [
                    "_name": "thunderboltusb4_bus_0",
                    "receptacle_1_tag": [
                        "current_speed_key": "Up to 40 Gb/s",
                        "receptacle_status_key": "receptacle_no_devices_connected",
                    ],
                ],
            ],
        ]
        XCTAssertTrue(ThunderboltParsing.parse(root: root).isEmpty, "无设备连接的 receptacle 应跳过")
    }

    func testDockWithNestedDevicesCollected() {
        let root: [String: Any] = [
            "SPThunderboltDataType": [
                [
                    "_name": "thunderboltusb4_bus_0",
                    "receptacle_1_tag": [
                        "current_speed_key": "Up to 40 Gb/s",
                        "receptacle_status_key": "receptacle_connected",
                        "device_name_key": "CalDigit Dock",
                        "vendor_name_key": "CalDigit, Inc.",
                        "device_type_key": "Peripherals",
                        "receptacle_2_tag": [
                            "device_name_key": "LG UltraFine",
                            "vendor_name_key": "LG",
                        ],
                    ],
                ],
            ],
        ]
        let devices = ThunderboltParsing.parse(root: root)

        XCTAssertEqual(devices.count, 2, "坞站和下挂显示器都要收集")
        XCTAssertEqual(devices.map(\.name), ["CalDigit Dock", "LG UltraFine"], "按名称稳定排序")
        XCTAssertEqual(devices[0].vendorName, "CalDigit, Inc.")
        XCTAssertEqual(devices[0].linkSpeedLabel, "Up to 40 Gb/s")
        XCTAssertEqual(devices[0].deviceType, "Peripherals")
        XCTAssertEqual(devices[0].receptaclePort, 1, "端口号应随设备保留")
        XCTAssertEqual(devices[1].linkSpeedLabel, nil, "下挂节点缺 current_speed_key 时回退 link_status_key/nil")
        XCTAssertEqual(devices[1].receptaclePort, 1, "级联子树继承外层 receptacle 编号")
    }

    /// 多 receptacle 场景：不同物理口的设备携带各自端口号（会话聚合的依据）
    func testMultipleReceptaclesKeepTheirNumbers() {
        let root: [String: Any] = [
            "SPThunderboltDataType": [
                [
                    "receptacle_1_tag": ["device_name_key": "Dock A"],
                    "receptacle_2_tag": ["device_name_key": "Dock B"],
                ],
            ],
        ]
        let devices = ThunderboltParsing.parse(root: root)
        XCTAssertEqual(devices.map(\.name), ["Dock A", "Dock B"])
        XCTAssertEqual(devices.map(\.receptaclePort), [1, 2])
    }

    func testUnknownStatusStillCollectedConservatively() {
        // status 缺失时保守不漏报
        let root: [String: Any] = [
            "SPThunderboltDataType": [
                ["receptacle_3_tag": ["device_name_key": "SSD"]],
            ],
        ]
        XCTAssertEqual(ThunderboltParsing.parse(root: root).map(\.name), ["SSD"])
        XCTAssertEqual(ThunderboltParsing.parse(root: root).first?.receptaclePort, 3)
    }

    func testArrayOfChildrenCollected() {
        // 部分系统把下挂设备放在数组里
        let root: [String: Any] = [
            "SPThunderboltDataType": [
                [
                    "receptacle_1_tag": [
                        "device_name_key": "Dock",
                        "sub_devices": [["device_name_key": "Monitor"]],
                    ],
                ],
            ],
        ]
        let devices = ThunderboltParsing.parse(root: root)
        XCTAssertEqual(devices.map(\.name), ["Dock", "Monitor"])
        XCTAssertTrue(devices.allSatisfy { $0.receptaclePort == 1 })
    }

    /// 非数字 receptacle 编号（receptacle_x_tag）不应崩溃，端口号降级为 nil
    func testNonNumericReceptacleNumberDecodesNil() {
        let root: [String: Any] = [
            "SPThunderboltDataType": [
                ["receptacle_x_tag": ["device_name_key": "Weird"]],
            ],
        ]
        let devices = ThunderboltParsing.parse(root: root)
        XCTAssertEqual(devices.map(\.name), ["Weird"])
        XCTAssertNil(devices.first?.receptaclePort)
    }

    // MARK: - 代际识别（M3）

    /// 链路速度标签 → 代际映射：80 / 40 / 20 / 22 各档、未知与缺失均不猜测
    func testGenerationMappingByLinkSpeedLabel() {
        XCTAssertEqual(ThunderboltGeneration.label(forLinkSpeedLabel: "Up to 80 Gb/s"), "雷雳 5")
        XCTAssertEqual(ThunderboltGeneration.label(forLinkSpeedLabel: "Up to 40 Gb/s"), "雷雳 4 / USB4")
        XCTAssertEqual(ThunderboltGeneration.label(forLinkSpeedLabel: "Up to 40Gb/s"),
                       "雷雳 4 / USB4", "无空格标签形态同样命中")
        XCTAssertEqual(ThunderboltGeneration.label(forLinkSpeedLabel: "Up to 20 Gb/s"), "雷雳 3")
        XCTAssertEqual(ThunderboltGeneration.label(forLinkSpeedLabel: "Up to 22 Gb/s"), "雷雳 3")
        XCTAssertNil(ThunderboltGeneration.label(forLinkSpeedLabel: "Up to 10 Gb/s"), "未知速度不猜测代际")
        XCTAssertNil(ThunderboltGeneration.label(forLinkSpeedLabel: nil), "标签缺失时为 nil")
    }

    /// 解析集成：generation 由 current_speed_key 反推并写入设备快照
    func testParsedDevicesCarryGeneration() {
        let root: [String: Any] = [
            "SPThunderboltDataType": [
                [
                    "receptacle_1_tag": [
                        "current_speed_key": "Up to 80 Gb/s",
                        "device_name_key": "TB5 Dock",
                    ],
                    "receptacle_2_tag": [
                        "current_speed_key": "Up to 40 Gb/s",
                        "device_name_key": "TB4 SSD",
                    ],
                    "receptacle_3_tag": [
                        "device_name_key": "Legacy Device",
                    ],
                ],
            ],
        ]
        let devices = ThunderboltParsing.parse(root: root)
        XCTAssertEqual(devices.map(\.name), ["Legacy Device", "TB4 SSD", "TB5 Dock"], "按名称稳定排序")
        XCTAssertEqual(devices.first { $0.name == "TB5 Dock" }?.generation, "雷雳 5")
        XCTAssertEqual(devices.first { $0.name == "TB4 SSD" }?.generation, "雷雳 4 / USB4")
        XCTAssertNil(devices.first { $0.name == "Legacy Device" }?.generation, "无速度标签时代际为 nil")
    }

    /// 旧 JSON（无 generation 键）解码兼容：缺失时视为 nil
    func testDecodingLegacyJSONWithoutGenerationKey() throws {
        // 手工构造 M3 之前落盘的设备 JSON（只含当时的键集合）
        let json = """
        {"name":"CalDigit Dock","vendorName":"CalDigit, Inc.","linkSpeedLabel":"Up to 40 Gb/s",\
        "deviceType":"Peripherals","receptaclePort":1}
        """
        let device = try JSONDecoder().decode(ThunderboltDeviceSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(device.name, "CalDigit Dock")
        XCTAssertEqual(device.receptaclePort, 1)
        XCTAssertNil(device.generation, "旧 JSON 缺 generation 键应解码为 nil")
    }

    /// round-trip：编码完整写出 generation，解码后还原一致
    func testGenerationRoundTrip() throws {
        let device = ThunderboltDeviceSnapshot(name: "SSD", vendorName: nil, linkSpeedLabel: "Up to 80 Gb/s",
                                               deviceType: nil, receptaclePort: 2, generation: "雷雳 5")
        let data = try JSONEncoder().encode(device)
        XCTAssertEqual(try JSONDecoder().decode(ThunderboltDeviceSnapshot.self, from: data), device)
        // 编码产物应显式包含 generation 键（新字段完整写出，供新版本读取）
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(object?["generation"] as? String, "雷雳 5")
    }
}
