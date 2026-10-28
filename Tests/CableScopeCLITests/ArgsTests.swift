import Foundation
import XCTest
@testable import CableScopeCLI

final class ArgsTests: XCTestCase {
    /// 断言里写的是中文输出：钉死 CLI 语言，否则在英文系统（CI runner）上跟随系统切成英文。
    private var savedLocale = CLILanguage.locale

    override func setUp() {
        super.setUp()
        savedLocale = CLILanguage.locale
        CLILanguage.locale = Locale(identifier: "zh-Hans")
    }

    override func tearDown() {
        CLILanguage.locale = savedLocale
        super.tearDown()
    }

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

    /// `Double("inf")` 能解析成功但不是有限值：透传下去会在
    /// `UInt64(interval * 1_000_000_000)` 处溢出陷阱（进程直接崩溃），
    /// "nan" 则让所有比较恒为 false。两者都必须在解析层被拒。
    ///
    /// 超大**有限**值（如 "1e20"）同样会崩——`isFinite` 挡不住它，故还要卡上限。
    func testWatchRejectsNonFiniteInterval() {
        assertUsageError(["watch", "--interval", "inf"], contains: "无效")
        assertUsageError(["watch", "--interval", "infinity"], contains: "无效")
        assertUsageError(["watch", "--interval", "nan"], contains: "无效")
        assertUsageError(["watch", "--interval=-inf"], contains: "无效")
    }

    /// 超大有限值：`Double("1e20")` 是有限值，但下游 `UInt64(interval * 1_000_000_000)`
    /// 会溢出陷阱（Fatal error，进程直接崩，不是报错）。必须在解析层被拒。
    func testWatchRejectsHugeFiniteInterval() {
        assertUsageError(["watch", "--interval", "1e20"], contains: "无效")
        assertUsageError(["watch", "--interval", "1e300"], contains: "无效")
        assertUsageError(["watch", "--interval", "99999999999999999999"], contains: "无效")
    }

    /// 极小值：下游 `UInt64(interval * 1e9)` 会**静默截断**成 0（不崩溃），
    /// 于是 `Task.sleep(nanoseconds: 0)` 立刻返回 → 轮询变成零延迟忙循环，
    /// 每轮都跑一次完整的 IOKit 采集，CPU 打满。
    func testWatchRejectsSubMillisecondInterval() {
        assertUsageError(["watch", "--interval", "1e-12"], contains: "无效")
        assertUsageError(["watch", "--interval", "0.0001"], contains: "无效")
        assertUsageError(["watch", "--interval=1e-9"], contains: "无效")
    }

    /// 下限边界本身是合法的（0.001 秒 = 1ms）。
    func testWatchAcceptsMinimumInterval() throws {
        XCTAssertEqual(try Args.parse(["watch", "--interval", "0.001"]), .watch(interval: 0.001))
    }

    // MARK: rating

    func testRatingDefaultsAndReset() throws {
        XCTAssertEqual(try Args.parse(["rating"]), .rating(reset: false))
        XCTAssertEqual(try Args.parse(["rating", "--reset"]), .rating(reset: true))
    }

    func testRatingRejectsUnknownFlag() {
        assertUsageError(["rating", "--clear"], contains: "rating 不支持参数")
    }

    // MARK: properties

    func testPropertiesDefaultsToUSBHostDevice() throws {
        XCTAssertEqual(try Args.parse(["properties"]),
                       .properties(className: CableScopeCLI.defaultRegistryClassName, json: false))
    }

    func testPropertiesWithClassNameAndJSON() throws {
        XCTAssertEqual(try Args.parse(["properties", "AppleSmartBattery"]),
                       .properties(className: "AppleSmartBattery", json: false))
        XCTAssertEqual(try Args.parse(["properties", "--json", "IODisplayConnect"]),
                       .properties(className: "IODisplayConnect", json: true))
        XCTAssertEqual(try Args.parse(["properties", "IOThunderboltPort", "--json"]),
                       .properties(className: "IOThunderboltPort", json: true))
    }

    func testPropertiesRejectsExtraPositionalAndUnknownFlag() {
        assertUsageError(["properties", "A", "B"], contains: "只接受一个类名")
        assertUsageError(["properties", "--pretty"], contains: "properties 不支持参数")
    }

    // MARK: throughput

    func testThroughputDefaults() throws {
        XCTAssertEqual(try Args.parse(["throughput"]), .throughput(volume: nil, seconds: 5.0))
    }

    func testThroughputVolumeAndSecondsBothForms() throws {
        XCTAssertEqual(try Args.parse(["throughput", "--volume", "/Volumes/USB盘"]),
                       .throughput(volume: "/Volumes/USB盘", seconds: 5.0))
        XCTAssertEqual(try Args.parse(["throughput", "--volume=SanDisk", "--seconds=0.3"]),
                       .throughput(volume: "SanDisk", seconds: 0.3))
        // 允许小数秒
        XCTAssertEqual(try Args.parse(["throughput", "--seconds", "1.5"]),
                       .throughput(volume: nil, seconds: 1.5))
    }

    func testThroughputLastFlagWins() throws {
        XCTAssertEqual(try Args.parse(["throughput", "--seconds", "3", "--seconds=8"]),
                       .throughput(volume: nil, seconds: 8.0))
        XCTAssertEqual(try Args.parse(["throughput", "--volume", "A", "--volume", "B"]),
                       .throughput(volume: "B", seconds: 5.0))
    }

    func testThroughputInvalidSeconds() {
        assertUsageError(["throughput", "--seconds", "0"], contains: "无效")
        assertUsageError(["throughput", "--seconds", "-1"], contains: "无效")
        assertUsageError(["throughput", "--seconds", "abc"], contains: "无效")
        assertUsageError(["throughput", "--seconds"], contains: "需要一个数值")
    }

    /// 同 watch --interval：非有限值必须被拒，否则下游 `UInt64(seconds * 1e9)` 溢出。
    func testThroughputRejectsNonFiniteSeconds() {
        assertUsageError(["throughput", "--seconds", "inf"], contains: "无效")
        assertUsageError(["throughput", "--seconds", "nan"], contains: "无效")
        assertUsageError(["throughput", "--seconds=-inf"], contains: "无效")
    }

    /// 超大有限值同样会崩（`Duration.seconds(1e300)` / `UInt64(1e20 * 1e9)` 溢出）。
    func testThroughputRejectsHugeFiniteSeconds() {
        assertUsageError(["throughput", "--seconds", "1e20"], contains: "无效")
        assertUsageError(["throughput", "--seconds", "1e300"], contains: "无效")
    }

    /// 极小值会被 `UInt64(seconds * 1e9)` 静默截断成 0 → 测速阶段瞬时结束，
    /// 拿不到任何有效数据。
    func testThroughputRejectsSubMillisecondSeconds() {
        assertUsageError(["throughput", "--seconds", "1e-12"], contains: "无效")
        assertUsageError(["throughput", "--seconds", "0.0001"], contains: "无效")
    }

    func testThroughputVolumeNeedsValueAndRejectsUnknownFlag() {
        assertUsageError(["throughput", "--volume"], contains: "需要一个挂载点路径或卷名")
        assertUsageError(["throughput", "--volume=--seconds"], contains: "需要一个挂载点路径或卷名")
        assertUsageError(["throughput", "--bogus"], contains: "throughput 不支持参数")
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
