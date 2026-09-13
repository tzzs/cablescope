import XCTest
@testable import CableKit

/// RatingStore 的双存储迁移测试（临时目录注入，不触碰真实 Application Support）。
final class RatingStoreTests: XCTestCase {
    private var workDir: URL!
    private var canonicalURL: URL!
    private var legacyURL: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RatingStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        canonicalURL = workDir.appendingPathComponent("ratings.json")
        legacyURL = workDir.appendingPathComponent("app-ratings.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    private func makeSnapshot(portKey: UInt32, bitsPerSecond: Int, watts: Double) -> CableSnapshot {
        let device = USBDeviceSnapshot(
            registryID: UInt64.random(in: 1...1_000_000),
            locationID: portKey << 20,
            physicalPortID: nil,
            productName: "测试设备",
            vendorName: nil, vendorID: nil, productID: nil, serialNumber: nil,
            bcdUSB: nil,
            speed: USBSpeed(bitsPerSecond: bitsPerSecond)
        )
        var engine = CableRatingEngine()
        let power = PowerSnapshot(isCharging: true, batteryPercent: 50,
                                  adapterVoltageMV: 20_000, adapterAmperageMA: Int(watts * 1000 / 20),
                                  pdContract: PDContract(voltageMV: 20_000, currentMA: 5_000),
                                  adapterDescription: nil, cycleCount: nil)
        let snapshot = CableSnapshot(usbDevices: [device], power: power,
                                     displays: [], thunderboltDevices: [])
        engine.record(snapshot)
        return snapshot
    }

    func testLegacyFileIsMergedAndRemoved() throws {
        // App 旧存储：端口 A 10Gbps；CLI 存储：同一端口 5Gbps（应取峰值 10G）。
        var legacyEngine = CableRatingEngine()
        legacyEngine.record(makeSnapshot(portKey: 0x14, bitsPerSecond: 10_000_000_000, watts: 0))
        try legacyEngine.save(to: legacyURL)

        var cliEngine = CableRatingEngine()
        cliEngine.record(makeSnapshot(portKey: 0x14, bitsPerSecond: 5_000_000_000, watts: 0))
        try cliEngine.save(to: canonicalURL)

        let merged = RatingStore.loadEngine(canonicalURL: canonicalURL, legacyURL: legacyURL)
        let rating = merged.rating(forSessionID: PortGrouping.sessionID(forPortKey: 0x14))

        XCTAssertEqual(rating?.maxUSBBitsPerSecond, 10_000_000_000, "同端口取峰值较大者")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path),
                       "迁移成功后旧文件应删除（防 --reset 后旧数据复活）")
    }

    func testLegacyMergedWhenCanonicalMissing() throws {
        var legacyEngine = CableRatingEngine()
        legacyEngine.record(makeSnapshot(portKey: 0x15, bitsPerSecond: 480_000_000, watts: 0))
        try legacyEngine.save(to: legacyURL)

        let engine = RatingStore.loadEngine(canonicalURL: canonicalURL, legacyURL: legacyURL)
        XCTAssertEqual(engine.rating(forSessionID: "usb-0x015")?.maxUSBBitsPerSecond, 480_000_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: canonicalURL.path), "迁移结果应落盘 canonical")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
    }

    func testCorruptedLegacyFileIsCleanedUp() throws {
        try Data("不是 JSON".utf8).write(to: legacyURL)
        let engine = RatingStore.loadEngine(canonicalURL: canonicalURL, legacyURL: legacyURL)
        XCTAssertEqual(engine.overallRating().sampleCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path), "损坏的旧文件应被清理")
    }

    func testEngineMergeIsIdempotent() throws {
        var engineA = CableRatingEngine()
        engineA.record(makeSnapshot(portKey: 0x16, bitsPerSecond: 5_000_000_000, watts: 0))

        var engineB = CableRatingEngine()
        engineB.record(makeSnapshot(portKey: 0x16, bitsPerSecond: 10_000_000_000, watts: 0))

        engineA.merge(engineB)
        let first = engineA.rating(forSessionID: "usb-0x016")?.maxUSBBitsPerSecond
        XCTAssertEqual(first, 10_000_000_000)

        let sampleCountBefore = engineA.rating(forSessionID: "usb-0x016")?.sampleCount
        engineA.merge(engineB)
        let sampleCountAfter = engineA.rating(forSessionID: "usb-0x016")?.sampleCount
        XCTAssertEqual(sampleCountBefore, sampleCountAfter, "重复合并不应膨胀计数（幂等）")
    }
}
