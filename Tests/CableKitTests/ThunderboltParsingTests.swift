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
        XCTAssertEqual(devices[1].linkSpeedLabel, nil, "下挂节点缺 current_speed_key 时回退 link_status_key/nil")
    }

    func testUnknownStatusStillCollectedConservatively() {
        // status 缺失时保守不漏报
        let root: [String: Any] = [
            "SPThunderboltDataType": [
                ["receptacle_3_tag": ["device_name_key": "SSD"]],
            ],
        ]
        XCTAssertEqual(ThunderboltParsing.parse(root: root).map(\.name), ["SSD"])
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
        XCTAssertEqual(ThunderboltParsing.parse(root: root).map(\.name), ["Dock", "Monitor"])
    }
}
