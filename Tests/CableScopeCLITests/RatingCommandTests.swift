import CableKit
import Foundation
import XCTest
@testable import CableScopeCLI

/// `rating` 子命令：历史清空与评级报告的渲染。
///
/// **绝不能碰用户真实的评级历史**（`~/Library/Application Support/CableScope/ratings.json`）：
/// 每个用例都注入一个临时目录里的路径。
final class RatingCommandTests: XCTestCase {
    private var savedLocale = CLILanguage.locale
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        savedLocale = CLILanguage.locale
        CLILanguage.locale = Locale(identifier: "zh-Hans")
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cablescope-rating-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        CLILanguage.locale = savedLocale
        super.tearDown()
    }

    private func storeURL() -> URL {
        tempDirectory.appendingPathComponent("ratings.json")
    }

    private func makeRating(sampleCount: Int = 3,
                            firstSeen: Date? = nil,
                            lastSeen: Date? = nil) -> CableRating {
        CableRating(maxUSBBitsPerSecond: 10_000_000_000,
                    maxChargingWatts: 100,
                    is5ACable: true,
                    maxDisplayLinkRate: "hbr3",
                    maxRefreshRateHz: 60,
                    sampleCount: sampleCount,
                    firstSeen: firstSeen,
                    lastSeen: lastSeen)
    }

    // MARK: --reset

    /// 历史文件存在时：`--reset` 删掉它并报告路径。
    func testResetDeletesExistingHistory() async throws {
        let url = storeURL()
        try Data("{}".utf8).write(to: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let output = try await CLITestSupport.captureStandardOutput {
            try await CableScopeCLI.runRating(reset: true, storeURL: url)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "评级历史应被删除")
        XCTAssertTrue(output.contains("已清空评级历史"), output)
        XCTAssertTrue(output.contains(url.path), output)
    }

    /// 历史文件不存在时不是错误，只是"没有可清空的历史"，且不创建空文件。
    func testResetWithoutHistoryReportsNothingToClear() async throws {
        let url = storeURL()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        let output = try await CLITestSupport.captureStandardOutput {
            try await CableScopeCLI.runRating(reset: true, storeURL: url)
        }

        XCTAssertTrue(output.contains("没有可清空的历史"), output)
        XCTAssertTrue(output.contains(url.path), output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "不应凭空创建历史文件")
    }

    /// 删不掉时必须报错，而不是假装成功。
    ///
    /// 用「父目录去掉写权限」制造删除失败（`removeItem` 是递归的，非空目录也删得掉，
    /// 造不出那种失败）；root 无视目录权限，因此 root 下跳过本用例。
    func testResetFailureThrowsRuntimeError() async throws {
        try XCTSkipIf(getuid() == 0, "root 可以无视目录权限，无法制造删除失败")

        let lockedDirectory = tempDirectory.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: lockedDirectory, withIntermediateDirectories: true)
        let url = lockedDirectory.appendingPathComponent("ratings.json")
        try Data("{}".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: lockedDirectory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: lockedDirectory.path)
        }

        do {
            _ = try await CLITestSupport.captureStandardOutput {
                try await CableScopeCLI.runRating(reset: true, storeURL: url)
            }
            XCTFail("删除失败时应当抛出 RuntimeError")
        } catch let error as RuntimeError {
            XCTAssertTrue(error.description.contains("清空评级历史失败"), error.description)
        } catch {
            XCTFail("错误类型不对：\(error)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "删不掉的历史文件应保留")
    }

    // MARK: 评级报告渲染

    func testRatingLinesReportSampleCountSummaryAndSavedPath() {
        let url = storeURL()
        let lines = CableScopeCLI.ratingLines(makeRating(sampleCount: 7), storeURL: url)

        XCTAssertEqual(lines.count, 3, "没有观测窗口时是三行：\(lines)")
        XCTAssertTrue(lines[0].contains("线缆评级（基于 7 次协商观测）"), lines[0])
        XCTAssertTrue(lines[1].contains("USB 3.x Gen2 10 Gbps"), lines[1])
        XCTAssertTrue(lines[1].contains("⚡ 100W（至少支持 5A）"), lines[1])
        XCTAssertTrue(lines[2].contains("已保存到 \(url.path)"), lines[2])
    }

    /// 有首末观测时间时多一行观测窗口，两端时间都要出现。
    func testRatingLinesIncludeObservationWindow() {
        let first = Date(timeIntervalSince1970: 1_767_225_600)
        let last = Date(timeIntervalSince1970: 1_767_312_000)
        let lines = CableScopeCLI.ratingLines(makeRating(firstSeen: first, lastSeen: last), storeURL: storeURL())

        XCTAssertEqual(lines.count, 4, lines.joined(separator: "\n"))
        let expected = "观测窗口：首次 \(Fmt.timeString(first, format: "yyyy-MM-dd HH:mm"))"
            + " · 最近 \(Fmt.timeString(last, format: "yyyy-MM-dd HH:mm"))"
        XCTAssertTrue(lines[2].contains(expected), lines[2])
    }

    /// 只测到一侧时间时，窗口里只出现那一侧，不写空的另一半。
    func testRatingLinesWindowWithOnlyFirstSeen() {
        let first = Date(timeIntervalSince1970: 1_767_225_600)
        let lines = CableScopeCLI.ratingLines(makeRating(firstSeen: first), storeURL: storeURL())

        XCTAssertEqual(lines.count, 4, lines.joined(separator: "\n"))
        XCTAssertTrue(lines[2].contains("首次 \(Fmt.timeString(first, format: "yyyy-MM-dd HH:mm"))"), lines[2])
        XCTAssertFalse(lines[2].contains("最近"), lines[2])
    }

    /// 什么都没观测到时也要给出一行摘要，而不是空输出。
    func testRatingLinesWithoutAnyObservationStillHasSummary() {
        let rating = CableRating(maxUSBBitsPerSecond: nil, maxChargingWatts: nil, is5ACable: false,
                                 maxDisplayLinkRate: nil, maxRefreshRateHz: nil, sampleCount: 0,
                                 firstSeen: nil, lastSeen: nil)
        let lines = CableScopeCLI.ratingLines(rating, storeURL: storeURL())

        XCTAssertEqual(lines.count, 3, lines.joined(separator: "\n"))
        XCTAssertTrue(lines[1].contains("未观测到高速 USB 协商"), lines[1])
    }
}
