import XCTest
@testable import CableKit

/// 数据契约模型的边界与编解码测试（纯值类型，不依赖系统状态）。
final class CableModelTests: XCTestCase {

    // MARK: - USBSpeed 边界

    func testUSBSpeedGenerationBoundaries() {
        // 低于阈值属于上一档；恰好等于阈值进入更高档（与实现中的 `<` 区间一致）
        XCTAssertEqual(USBSpeed(bitsPerSecond: 1_499_999).generation, "Low Speed")
        XCTAssertEqual(USBSpeed(bitsPerSecond: 1_500_000).generation, "Full Speed (USB 1.1)")
        XCTAssertEqual(USBSpeed(bitsPerSecond: 480_000_000).generation, "USB 2.0")
        XCTAssertEqual(USBSpeed(bitsPerSecond: 5_000_000_000).generation, "USB 3.x Gen1")
        XCTAssertEqual(USBSpeed(bitsPerSecond: 10_000_000_000).generation, "USB 3.x Gen2")
        XCTAssertEqual(USBSpeed(bitsPerSecond: 20_000_000_000).generation, "USB 3.x Gen2x2")
        XCTAssertEqual(USBSpeed(bitsPerSecond: 40_000_000_000).generation, "USB4 / Thunderbolt")
    }

    func testUSBSpeedLabels() {
        XCTAssertEqual(USBSpeed(bitsPerSecond: 480_000_000).label, "480 Mbps")
        XCTAssertEqual(USBSpeed(bitsPerSecond: 5_000_000_000).label, "5 Gbps")
        XCTAssertEqual(USBSpeed(bitsPerSecond: 10_000_000_000).label, "10 Gbps")
        XCTAssertEqual(USBSpeed(bitsPerSecond: 40_000_000_000).label, "40 Gbps")
        // 非整数 Gbps 不出现小数尾巴
        XCTAssertEqual(USBSpeed(bitsPerSecond: 1_500_000).label, "2 Mbps")
    }

    // MARK: - PDContract.implies5ACable

    func testPDContractImplies5ACableBoundaries() {
        XCTAssertTrue(PDContract(voltageMV: 20_000, currentMA: 5_000).implies5ACable, "20V/5A 应为 5A 线")
        XCTAssertFalse(PDContract(voltageMV: 20_000, currentMA: 3_000).implies5ACable, "20V/3A 不是 5A 线")
        XCTAssertFalse(PDContract(voltageMV: 19_000, currentMA: 5_000).implies5ACable, "19V/5A 不是 20V 合同")
        XCTAssertFalse(PDContract(voltageMV: 19_999, currentMA: 4_999).implies5ACable, "边界之下不触发")
        XCTAssertTrue(PDContract(voltageMV: 28_000, currentMA: 5_000).implies5ACable, "超过阈值仍触发")
        // 功率计算
        XCTAssertEqual(PDContract(voltageMV: 20_000, currentMA: 5_000).watts, 100, accuracy: 0.001)
        XCTAssertEqual(PDContract(voltageMV: 9_000, currentMA: 3_000).watts, 27, accuracy: 0.001)
    }

    // MARK: - CableSnapshot JSON round-trip

    func testSnapshotJSONRoundTripWithChineseNameAndNilOptionals() throws {
        let snapshot = CableSnapshot(
            id: UUID(uuidString: "DEADBEEF-1234-5678-9ABC-DEF012345678")!,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000), // 整秒，iso8601 可无损往返
            usbDevices: [
                USBDeviceSnapshot(registryID: 0x1234,
                                  locationID: 0x14100000,
                                  productName: "移动硬盘 测试款",
                                  vendorName: "深圳厂商",
                                  vendorID: 0x1234,
                                  productID: 0x5678,
                                  serialNumber: "SN-中文-001",
                                  bcdUSB: "0320",
                                  speed: USBSpeed(bitsPerSecond: 10_000_000_000)),
                USBDeviceSnapshot(registryID: 2,
                                  locationID: 0x14200000,
                                  productName: nil,
                                  vendorName: nil,
                                  vendorID: nil,
                                  productID: nil,
                                  serialNumber: nil,
                                  bcdUSB: nil,
                                  speed: nil),
            ],
            power: PowerSnapshot(isCharging: true,
                                 batteryPercent: 61,
                                 adapterVoltageMV: 20_000,
                                 adapterAmperageMA: 3_627,
                                 pdContract: PDContract(voltageMV: 20_000, currentMA: 5_000),
                                 adapterDescription: "pd charger",
                                 cycleCount: 40),
            displays: [
                DisplaySnapshot(displayID: 1,
                                name: "Color LCD",
                                pixelWidth: 2940,
                                pixelHeight: 1912,
                                refreshRateHz: 60.0,
                                linkRateLabel: nil,
                                isMain: true),
            ],
            thunderboltDevices: []
        )

        let data = try snapshot.toJSON(pretty: true)
        let decoded = try CableSnapshot.fromJSON(data)

        XCTAssertEqual(decoded, snapshot, "JSON 编解码应无损往返")
        // 显式校验中文与可选字段
        XCTAssertEqual(decoded.usbDevices.first?.productName, "移动硬盘 测试款")
        XCTAssertEqual(decoded.usbDevices.last?.productName, nil)
        XCTAssertEqual(decoded.usbDevices.last?.speed, nil)
        XCTAssertEqual(decoded.power?.pdContract?.implies5ACable, true)
    }

    func testSnapshotJSONRoundTripWithoutPower() throws {
        let snapshot = CableSnapshot(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            usbDevices: [],
            power: nil,
            displays: [],
            thunderboltDevices: []
        )
        let decoded = try CableSnapshot.fromJSON(snapshot.toJSON())
        XCTAssertEqual(decoded, snapshot)
        XCTAssertNil(decoded.power)
        XCTAssertTrue(decoded.usbDevices.isEmpty)
    }
}
