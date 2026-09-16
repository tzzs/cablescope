import XCTest
@testable import CableKit

final class CableRatingEngineTests: XCTestCase {
    private func makePower(watts: (Double, Double), voltsMV: Int, ampsMA: Int, charging: Bool = true,
                           external: Bool = true) -> PowerSnapshot {
        let contract = PDContract(voltageMV: voltsMV, currentMA: ampsMA)
        return PowerSnapshot(isCharging: charging,
                             batteryPercent: 50,
                             adapterVoltageMV: voltsMV,
                             adapterAmperageMA: ampsMA,
                             pdContract: contract,
                             adapterDescription: nil,
                             cycleCount: nil,
                             externalConnected: external)
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
        let summary = rating.summary(locale: Locale(identifier: "zh-Hans"))
        XCTAssertFalse(summary.contains("0 Mbps"), "summary 不应把无数据渲染成 0 Mbps")
        XCTAssertFalse(summary.contains("⚡ 0W"), "summary 不应把无数据渲染成 0W")
        XCTAssertTrue(summary.contains("未观测到高速 USB 协商"))
    }

    /// 多端口聚合：各线缆会话独立评级，overall 取跨端口峰值
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

        XCTAssertEqual(engine.rating(forSessionID: "usb-0x141")?.maxUSBBitsPerSecond, 480_000_000)
        XCTAssertEqual(engine.rating(forSessionID: "usb-0x142")?.maxUSBBitsPerSecond, 40_000_000_000)
        XCTAssertNil(engine.rating(forSessionID: "usb-0x999"), "未知端口无评级")
        XCTAssertEqual(engine.overallRating().maxUSBBitsPerSecond, 40_000_000_000, "overall 取跨端口峰值")
        // overall 的 sampleCount = 各桶最大值（近似最长观测窗口），避免多线并插时同一次快照被重复计数
        XCTAssertEqual(engine.overallRating().sampleCount, 1)
    }

    /// 电源归属：仅一根线时充电功率/5A 合同记入该线会话桶
    func testPowerAttributionWithSingleSession() {
        var engine = CableRatingEngine()
        let device = USBDeviceSnapshot(registryID: 1, locationID: 0x14100000, productName: "A",
                                       vendorName: nil, vendorID: nil, productID: nil, serialNumber: nil,
                                       bcdUSB: nil, speed: USBSpeed(bitsPerSecond: 5_000_000_000))

        engine.record(CableSnapshot(usbDevices: [device], power: makePower(watts: (60, 60), voltsMV: 20_000, ampsMA: 3_000),
                                    displays: [], thunderboltDevices: []))

        let portRating = engine.rating(forSessionID: "usb-0x141")
        XCTAssertEqual(portRating?.maxChargingWatts ?? 0, 60, accuracy: 0.01)
        XCTAssertFalse(portRating?.is5ACable ?? true, "20V/3A 不触发 5A")
        XCTAssertNil(engine.rating(forSessionID: CableRatingEngine.systemKey), "单线时电源归属该线，不应产生整机桶")
    }

    /// 电源归属：多根线时充电数据无法按线归属，记入整机桶
    func testPowerAttributionWithMultipleSessionsGoesToSystem() {
        var engine = CableRatingEngine()
        let usbA = USBDeviceSnapshot(registryID: 1, locationID: 0x14100000, productName: "A",
                                     vendorName: nil, vendorID: nil, productID: nil, serialNumber: nil,
                                     bcdUSB: nil, speed: USBSpeed(bitsPerSecond: 480_000_000))
        let usbB = USBDeviceSnapshot(registryID: 2, locationID: 0x14200000, productName: "B",
                                     vendorName: nil, vendorID: nil, productID: nil, serialNumber: nil,
                                     bcdUSB: nil, speed: USBSpeed(bitsPerSecond: 40_000_000_000))

        engine.record(CableSnapshot(usbDevices: [usbA, usbB], power: makePower(watts: (60, 60), voltsMV: 20_000, ampsMA: 3_000),
                                    displays: [], thunderboltDevices: []))

        XCTAssertNil(engine.rating(forSessionID: "usb-0x141")?.maxChargingWatts, "多线时电源不归属单线")
        XCTAssertNil(engine.rating(forSessionID: "usb-0x142")?.maxChargingWatts)
        XCTAssertEqual(engine.rating(forSessionID: CableRatingEngine.systemKey)?.maxChargingWatts ?? 0, 60, accuracy: 0.01)
        // USB 速率仍按线分桶
        XCTAssertEqual(engine.rating(forSessionID: "usb-0x141")?.maxUSBBitsPerSecond, 480_000_000)
        XCTAssertEqual(engine.rating(forSessionID: "usb-0x142")?.maxUSBBitsPerSecond, 40_000_000_000)
    }

    /// 端口控制器时代的多线归属：纯 PD 充电线（不枚举任何 USB 设备）靠 winning 端口
    /// 把充电功率记进自己的线缆桶，显示器线不背锅，整机桶保持干净。
    func testPowerAttributionWithPortControllerSessions() {
        var engine = CableRatingEngine()

        func makePort(portID: String, winning: PDOPhase? = nil) -> USBCPortSnapshot {
            USBCPortSnapshot(portID: portID, controllerClass: "AppleHPMInterfaceType10",
                             portType: "USB-C", plugOrientation: nil, isActive: true, hasActiveCable: false,
                             connectionCount: nil, transportsSupported: ["CC"], transportsProvisioned: ["CC"],
                             featuresEnabled: [], eMarker: nil, partner: nil,
                             powerSource: winning.map { PDOPortPowerSnapshot(sourceName: "USB-PD",
                                                                             options: [$0], winning: $0) })
        }
        let winning = PDOPhase(voltageMV: 20_000, maxCurrentMA: 5_000, maxPowerMW: 100_000, uuid: nil)

        engine.record(CableSnapshot(usbDevices: [],
                                    power: makePower(watts: (98, 100), voltsMV: 20_000, ampsMA: 5_000),
                                    displays: [],
                                    thunderboltDevices: [],
                                    ports: [makePort(portID: "Port-USB-C@1"),
                                            makePort(portID: "Port-USB-C@2", winning: winning)]))

        let chargerRating = engine.rating(forSessionID: "Port-USB-C@2")
        XCTAssertEqual(chargerRating?.maxChargingWatts ?? 0, 100, accuracy: 0.01,
                       "充电数据归属 winning 端口的会话（sessions 由 record 现算；功率取 20V×5A）")
        XCTAssertTrue(chargerRating?.is5ACable ?? false)
        XCTAssertNil(engine.rating(forSessionID: "Port-USB-C@1")?.maxChargingWatts,
                     "显示器线不应记到充电功率")
        XCTAssertNil(engine.rating(forSessionID: CableRatingEngine.systemKey)?.maxChargingWatts,
                     "可归属时不进整机桶")
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
        let summary = rating.summary(locale: Locale(identifier: "zh-Hans"))
        XCTAssertTrue(summary.contains("HBR3"))
        XCTAssertTrue(summary.contains("120Hz"))
    }

    /// 空引擎：无任何观测时不得产生误导性的 0 值
    func testEmptyEngineProducesNilRating() {
        let engine = CableRatingEngine()
        let rating = engine.overallRating()
        XCTAssertNil(rating.maxUSBBitsPerSecond)
        XCTAssertNil(rating.maxChargingWatts)
        XCTAssertEqual(rating.sampleCount, 0)
        XCTAssertTrue(rating.summary(locale: Locale(identifier: "zh-Hans")).contains("未观测到高速 USB 协商"))
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
        XCTAssertEqual(loaded.rating(forSessionID: "usb-0x142")?.maxUSBBitsPerSecond, 5_000_000_000)
        try? FileManager.default.removeItem(at: url)
    }

    /// v1 → v2 存储迁移：旧 key 为完整 LocationID，经 >>20 映射为会话 id；
    /// 0 号桶（整机兜底）→ "sys"；多个旧 key 坍缩到同一会话时按峰值合并。
    /// v1 的 [UInt32: PortHistory] 经 JSONEncoder 产物是"键值交替数组"（实测确认），
    /// 这里按同格式构造旧文件。
    func testLegacyStoreMigration() throws {
        func historyDict(bps: Int?, watts: Double?, saw5A: Bool, link: String?, hz: Double?,
                         samples: Int, first: String?) -> [String: Any] {
            var dict: [String: Any] = ["saw5AContract": saw5A, "sampleCount": samples]
            if let bps { dict["maxUSBBitsPerSecond"] = bps }
            if let watts { dict["maxChargingWatts"] = watts }
            if let link { dict["maxDisplayLinkRate"] = link }
            if let hz { dict["maxRefreshRateHz"] = hz }
            if let first {
                dict["firstSeen"] = first
                dict["lastSeen"] = first
            }
            return dict
        }

        let legacy: [String: Any] = [
            "histories": [
                // 与 0x14110000 同根端口（0x141），应坍缩合并且峰值不缩水
                0x14100000, historyDict(bps: 10_000_000_000, watts: 100.0, saw5A: true, link: nil, hz: nil,
                                        samples: 7, first: "2026-08-30T10:00:00Z"),
                0x14110000, historyDict(bps: 5_000_000_000, watts: nil, saw5A: false, link: nil, hz: nil,
                                        samples: 2, first: nil),
                0, historyDict(bps: nil, watts: nil, saw5A: false, link: "HBR3", hz: 60.0,
                               samples: 3, first: nil),
            ],
        ]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-rating-\(UUID()).json")
        try JSONSerialization.data(withJSONObject: legacy).write(to: url)

        let engine = try CableRatingEngine.load(from: url)

        let portRating = engine.rating(forSessionID: "usb-0x141")
        XCTAssertEqual(portRating?.maxUSBBitsPerSecond, 10_000_000_000, "坍缩桶取峰值合并")
        XCTAssertTrue(portRating?.is5ACable ?? false)
        XCTAssertEqual(portRating?.sampleCount, 7, "合并取最大观测数")
        XCTAssertEqual(portRating?.firstSeen, ISO8601DateFormatter().date(from: "2026-08-30T10:00:00Z"))

        let sysRating = engine.rating(forSessionID: CableRatingEngine.systemKey)
        XCTAssertEqual(sysRating?.maxDisplayLinkRate, "HBR3", "旧 0 号桶迁移到整机桶")
        XCTAssertEqual(sysRating?.maxRefreshRateHz ?? 0, 60, accuracy: 0.01)
        try? FileManager.default.removeItem(at: url)
    }
}
