import XCTest
@testable import CableScopeCLI

final class ArgsTests: XCTestCase {
    func assertUsageError(_ arguments: [String], contains expected: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try Args.parse(arguments), file: file, line: line) { error in
            guard let usage = error as? UsageError else {
                return XCTFail("期望 UsageError，实际 \(error)", file: file, line: line)
            }
            XCTAssertTrue(usage.description.contains(expected),
                          "错误信息「\(usage.description)」应包含「\(expected)」", file: file, line: line)
        }
    }

    // MARK: snapshot

    func testNoArgumentsDefaultsToCompactSnapshot() throws {
        XCTAssertEqual(try Args.parse([]), .snapshot(pretty: false))
    }

    func testSnapshotPretty() throws {
        XCTAssertEqual(try Args.parse(["snapshot", "--pretty"]), .snapshot(pretty: true))
    }

    func testSnapshotRejectsUnknownFlag() {
        assertUsageError(["snapshot", "--json"], contains: "snapshot 不支持参数")
    }

    // MARK: pretty

    func testPrettyNoFlags() throws {
        XCTAssertEqual(try Args.parse(["pretty"]), .pretty)
    }

    func testPrettyRejectsFlags() {
        assertUsageError(["pretty", "extra"], contains: "pretty 不支持参数")
    }

    // MARK: watch

    func testWatchDefaultInterval() throws {
        XCTAssertEqual(try Args.parse(["watch"]), .watch(interval: 2.0))
    }

    func testWatchIntervalBothForms() throws {
        XCTAssertEqual(try Args.parse(["watch", "--interval", "5"]), .watch(interval: 5.0))
        XCTAssertEqual(try Args.parse(["watch", "--interval=0.5"]), .watch(interval: 0.5))
    }

    func testWatchLastIntervalWins() throws {
        XCTAssertEqual(try Args.parse(["watch", "--interval", "5", "--interval=3"]), .watch(interval: 3.0))
    }

    func testWatchInvalidIntervals() {
        assertUsageError(["watch", "--interval", "0"], contains: "无效")
        assertUsageError(["watch", "--interval", "-1"], contains: "无效")
        assertUsageError(["watch", "--interval", "abc"], contains: "无效")
        assertUsageError(["watch", "--interval"], contains: "需要一个数值")
        assertUsageError(["watch", "--bogus"], contains: "watch 不支持参数")
    }

    // MARK: rating

    func testRatingDefaultsAndReset() throws {
        XCTAssertEqual(try Args.parse(["rating"]), .rating(reset: false))
        XCTAssertEqual(try Args.parse(["rating", "--reset"]), .rating(reset: true))
    }

    func testRatingRejectsUnknownFlag() {
        assertUsageError(["rating", "--clear"], contains: "rating 不支持参数")
    }

    // MARK: help

    func testHelpAnywhere() throws {
        XCTAssertEqual(try Args.parse(["-h"]), .help)
        XCTAssertEqual(try Args.parse(["--help"]), .help)
        XCTAssertEqual(try Args.parse(["help"]), .help)
        XCTAssertEqual(try Args.parse(["snapshot", "--help"]), .help)
    }

    // MARK: 未知命令

    func testUnknownCommand() {
        assertUsageError(["snap"], contains: "未知命令")
        assertUsageError(["SNAPSHOT"], contains: "未知命令")
    }
}
