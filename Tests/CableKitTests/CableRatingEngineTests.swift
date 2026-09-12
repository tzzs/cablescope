import XCTest
@testable import CableKit

final class CableRatingEngineTests: XCTestCase {
    private func makePower(watts: (Double, Double), voltsMV: Int, ampsMA: Int, charging: Bool = true) -> PowerSnapshot {
        let contract = PDContract(voltageMV: voltsMV, currentMA: ampsMA)
        return PowerSnapshot(isCharging: charging,
                             batteryPercent: 50,
                             adapterVoltageMV: voltsMV,
                             adapterAmperageMA: ampsMA,
                             pdContract: contract,
                             adapterDescription: nil,
                             cycleCount: nil)
    }

    func testRatingAggregatesPeaks() throws {
        var engine = CableRatingEngine()
        let device480 = USBDeviceSnapshot(registryID: 1, locationID: 0x14100000, productName: "Hub",
                                          vendorName: nil, vendorID: nil, productID: nil, serialNumber: nil,
                                          bcdUSB: "0210", speed: USBSpeed(bitsPerSecond: 480_000_000))
        let device10G = USBDeviceSnapshot(registryID: 2, locationID: 0x14100000, productName: "SSD",
                                          vendorName: nil, vendorID: nil, productID: nil, serialNumber: nil,
                                          bcdUSB: "0310", speed: USBSpeed(bitsPerSecond: 10_000_000_000))
        let power60W = makePower(watts: (60, 60), voltsMV: 20_000, ampsMA: 3_000)
        let power100W = makePower(watts: (100, 100), voltsMV: 20_000, ampsMA: 5_000)

        engine.record(CableSnapshot(usbDevices: [device480], power: power60W, displays: [], thunderboltDevices: []))
        engine.record(CableSnapshot(usbDevices: [device10G], power: power100W, displays: [], thunderboltDevices: []))

        let rating = engine.overallRating()
        XCTAssertEqual(rating.maxUSBBitsPerSecond, 10_000_000_000)
        XCTAssertEqual(rating.maxChargingWatts ?? 0, 100, accuracy: 0.01)
        XCTAssertTrue(rating.is5ACable, "20V/5A 合同应触发 e-marker 推断")
        XCTAssertEqual(rating.sampleCount, 2)
    }

    /// 回归测试：无 USB/功率观测时 overallRating 应保持 nil，不得归约成 0
    /// （曾导致 summary 输出误导性的 "Low Speed 0 Mbps · ⚡ 0W"）
    func testOverallRatingKeepsNilWhenNoObservation() {
        var engine = CableRatingEngine()
        let display = DisplaySnapshot(displayID: 1, name: "Built-in", pixelWidth: 2940, pixelHeight: 1912,
                                      refreshRateHz: 60, linkRateLabel: nil, isMain: true)
        engine.record(CableSnapshot(usbDevices: [], power: nil, displays: [display], thunderboltDevices: []))

        let rating = engine.overallRating()
        XCTAssertNil(rating.maxUSBBitsPerSecond)
        XCTAssertNil(rating.maxChargingWatts)
        XCTAssertFalse(rating.is5ACable)
        XCTAssertEqual(rating.sampleCount, 1)
        XCTAssertEqual(rating.maxRefreshRateHz ?? 0, 60, accuracy: 0.01)
        XCTAssertFalse(rating.summary.contains("0 Mbps"), "summary 不应把无数据渲染成 0 Mbps")
        XCTAssertFalse(rating.summary.contains("⚡ 0W"), "summary 不应把无数据渲染成 0W")
        XCTAssertTrue(rating.summary.contains("未观测到高速 USB 协商"))
    }

    /// 多端口聚合：各 LocationID 独立评级，overall 取跨端口峰值
    func testMultiLocationAggregation() {
        var engine = CableRatingEngine()
        let usbA = USBDeviceSnapshot(registryID: 1, locationID: 0x14100000, productName: "A",
                                     vendorName: nil, vendorID: nil, productID: nil, serialNumber: nil,
                                     bcdUSB: nil, speed: USBSpeed(bitsPerSecond: 480_000_000))
        let usbB = USBDeviceSnapshot(registryID: 2, locationID: 0x14200000, productName: "B",
                                     vendorName: nil, vendorID: nil, productID: nil, serialNumber: nil,
                                     bcdUSB: nil, speed: USBSpeed(bitsPerSecond: 40_000_000_000))

        engine.record(CableSnapshot(usbDevices: [usbA], power: nil, displays: [], thunderboltDevices: []))
        engine.record(CableSnapshot(usbDevices: [usbB], power: nil, displays: [], thunderboltDevices: []))

        XCTAssertEqual(engine.rating(forLocationID: 0x14100000)?.maxUSBBitsPerSecond, 480_000_000)
        XCTAssertEqual(engine.rating(forLocationID: 0x14200000)?.maxUSBBitsPerSecond, 40_000_000_000)
        XCTAssertNil(engine.rating(forLocationID: 0x99900000), "未知端口无评级")
        XCTAssertEqual(engine.overallRating().maxUSBBitsPerSecond, 40_000_000_000, "overall 取跨端口峰值")
        XCTAssertEqual(engine.overallRating().sampleCount, 2)
    }

    /// 显示器信息参与评级：链路速率与刷新率取历史峰值
    func testDisplayInfoAggregatedIntoRating() {
        var engine = CableRatingEngine()
        let display60 = DisplaySnapshot(displayID: 1, name: nil, pixelWidth: 3840, pixelHeight: 2160,
                                        refreshRateHz: 60, linkRateLabel: "HBR3", isMain: true)
        let display120 = DisplaySnapshot(displayID: 1, name: nil, pixelWidth: 3840, pixelHeight: 2160,
                                         refreshRateHz: 120, linkRateLabel: "HBR3", isMain: true)
        engine.record(CableSnapshot(usbDevices: [], power: nil, displays: [display60], thunderboltDevices: []))
        engine.record(CableSnapshot(usbDevices: [], power: nil, displays: [display120], thunderboltDevices: []))

        let rating = engine.overallRating()
        XCTAssertEqual(rating.maxRefreshRateHz ?? 0, 120, accuracy: 0.01)
        XCTAssertEqual(rating.maxDisplayLinkRate, "HBR3")
        XCTAssertTrue(rating.summary.contains("HBR3"))
        XCTAssertTrue(rating.summary.contains("120Hz"))
    }

    /// 空引擎：无任何观测时不得产生误导性的 0 值
    func testEmptyEngineProducesNilRating() {
        let engine = CableRatingEngine()
        let rating = engine.overallRating()
        XCTAssertNil(rating.maxUSBBitsPerSecond)
        XCTAssertNil(rating.maxChargingWatts)
        XCTAssertEqual(rating.sampleCount, 0)
        XCTAssertTrue(rating.summary.contains("未观测到高速 USB 协商"))
    }

    func testPersistenceRoundTrip() throws {
        var engine = CableRatingEngine()
        let device = USBDeviceSnapshot(registryID: 1, locationID: 0x14200000, productName: "Disk",
                                       vendorName: nil, vendorID: nil, productID: nil, serialNumber: nil,
                                       bcdUSB: nil, speed: USBSpeed(bitsPerSecond: 5_000_000_000))
        engine.record(CableSnapshot(usbDevices: [device], power: nil, displays: [], thunderboltDevices: []))

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rating-\(UUID()).json")
        try engine.save(to: url)
        let loaded = try CableRatingEngine.load(from: url)
        XCTAssertEqual(loaded.rating(forLocationID: 0x14200000)?.maxUSBBitsPerSecond, 5_000_000_000)
        try? FileManager.default.removeItem(at: url)
    }
}
