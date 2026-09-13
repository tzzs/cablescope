import CableKit
import XCTest
@testable import CableScopeCLI

final class FormattingTests: XCTestCase {
    // MARK: Fmt

    func testFmtWattsVoltsAmps() {
        XCTAssertEqual(Fmt.watts(100), "100.0 W")
        XCTAssertEqual(Fmt.watts(40.3), "40.3 W")
        XCTAssertEqual(Fmt.volts(20_000), "20.0 V")
        XCTAssertEqual(Fmt.amps(2014), "2.01 A")
    }

    func testFmtRawMbpsIntegerAndFraction() {
        XCTAssertEqual(Fmt.rawMbps(480_000_000), "480 Mbps")
        XCTAssertEqual(Fmt.rawMbps(10_000_000_000), "10000 Mbps")
        XCTAssertEqual(Fmt.rawMbps(480_500_000), "480.5 Mbps")
    }

    // MARK: USBDeviceSnapshot 展示扩展

    private func makeUSB(product: String? = nil, vendor: String? = nil, vid: UInt16? = nil, pid: UInt16? = nil,
                         speed: USBSpeed? = USBSpeed(bitsPerSecond: 480_000_000)) -> USBDeviceSnapshot {
        USBDeviceSnapshot(registryID: 1, locationID: 0x14100000, productName: product, vendorName: vendor,
                          vendorID: vid, productID: pid, serialNumber: nil, bcdUSB: nil, speed: speed)
    }

    func testDisplayNameFallbackChain() {
        XCTAssertEqual(makeUSB(product: "SSD", vendor: "Samsung").displayName, "SSD")
        XCTAssertEqual(makeUSB(product: nil, vendor: "Samsung").displayName, "Samsung")
        XCTAssertEqual(makeUSB(product: nil, vendor: nil).displayName, "未知设备")
    }

    func testIDDescription() {
        // 0x05AC 在内置 VID 目录里命中 Apple，VID 段附带厂商名
        XCTAssertEqual(makeUSB(product: nil, vendor: nil, vid: 0x05AC, pid: 0x2086).idDescription,
                       "VID 0x05AC (Apple, Inc.) · PID 0x2086")
        XCTAssertEqual(makeUSB(product: nil, vendor: nil).idDescription, "", "无 ID 时输出空串")
    }

    func testSpeedDescription() {
        XCTAssertEqual(makeUSB(speed: nil).speedDescription, "速率未知")
        let text = makeUSB(speed: USBSpeed(bitsPerSecond: 10_000_000_000)).speedDescription
        XCTAssertTrue(text.contains("10000 Mbps"), "含原始协商速率：\(text)")
        XCTAssertTrue(text.contains("USB 3.x Gen2"), "含速率归类：\(text)")
        XCTAssertTrue(text.contains("10 Gbps"), "含人类可读标签：\(text)")
    }

    // MARK: PowerSnapshot 摘要

    func testShortSummaryCharging() {
        let power = PowerSnapshot(isCharging: true, batteryPercent: 80,
                                  adapterVoltageMV: 20_000, adapterAmperageMA: 2014,
                                  pdContract: nil, adapterDescription: nil, cycleCount: nil)
        XCTAssertEqual(power.shortSummary, "40.3 W · 充电中")
    }

    func testShortSummaryIdleWithoutWatts() {
        let power = PowerSnapshot(isCharging: false, batteryPercent: 80,
                                  adapterVoltageMV: nil, adapterAmperageMA: nil,
                                  pdContract: nil, adapterDescription: nil, cycleCount: nil)
        XCTAssertEqual(power.shortSummary, "未接通电源")
    }

    /// 保温/优化充电暂停：插电但 IsCharging=false、瞬时电流为负，不得展示负功率
    func testShortSummaryConnectedButPaused() {
        let power = PowerSnapshot(isCharging: false, batteryPercent: 86,
                                  adapterVoltageMV: 20_000, adapterAmperageMA: -540,
                                  pdContract: PDContract(voltageMV: 20_000, currentMA: 5_000),
                                  adapterDescription: "pd charger", cycleCount: 40,
                                  externalConnected: true)
        XCTAssertEqual(power.shortSummary, "已接通电源 · 未在充电")
    }
}
