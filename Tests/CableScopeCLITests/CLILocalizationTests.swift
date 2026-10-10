import CableKit
import Foundation
import XCTest
@testable import CableScopeCLI

/// CLI 的英文输出：文案与 CableKit 共表，表没进资源包或 key 对不上时会静默退回中文，
/// 这里断言真实的英文结果。
final class CLILocalizationTests: XCTestCase {
    private var savedLocale = CLILanguage.locale

    override func tearDown() {
        CLILanguage.locale = savedLocale
        super.tearDown()
    }

    // MARK: - 语言解析

    func testExplicitOverrideWins() {
        let locale = CLILanguage.resolve(environment: ["CABLESCOPE_LANG": "en", "LC_ALL": "zh_CN.UTF-8"],
                                         preferredLanguages: ["zh-Hans-CN"])
        XCTAssertEqual(locale.identifier, "en")
    }

    func testLCAllIsHonoredAndEncodingStripped() {
        let locale = CLILanguage.resolve(environment: ["LC_ALL": "en_US.UTF-8"], preferredLanguages: ["zh-Hans"])
        XCTAssertEqual(locale.identifier, "en_US")
    }

    func testLangIsDeliberatelyIgnored() {
        // 终端常自动填 LANG=en_US.UTF-8；读它会把中文系统用户静默切成英文。
        let locale = CLILanguage.resolve(environment: ["LANG": "en_US.UTF-8"], preferredLanguages: ["zh-Hans-CN"])
        XCTAssertEqual(locale.identifier, "zh-Hans-CN")
    }

    func testPosixLocaleCountsAsUnset() {
        let locale = CLILanguage.resolve(environment: ["LC_ALL": "C"], preferredLanguages: ["en-US"])
        XCTAssertEqual(locale.identifier, "en-US")
    }

    // MARK: - 命令名

    func testHomebrewInvocationUsesInstalledCommandName() {
        XCTAssertEqual(Invocation.name(argv0: "/opt/homebrew/bin/cablescope"), "cablescope")
        XCTAssertEqual(Invocation.name(argv0: "/repo/.build/debug/CableScopeCLI"), "swift run CableScopeCLI")
    }

    func testHelpUsesGivenCommandNameInBothLanguages() {
        for chinese in [true, false] {
            let text = Help.text(command: "cablescope", chinese: chinese)
            XCTAssertTrue(text.contains("cablescope watch --interval 5"))
            XCTAssertFalse(text.contains("swift run"))
        }
        XCTAssertTrue(Help.text(command: "cablescope", chinese: false).contains("Usage:"))
    }

    // MARK: - 英文输出

    func testUsageErrorsAreEnglish() {
        CLILanguage.locale = Locale(identifier: "en")
        XCTAssertThrowsError(try Args.parse(["watch", "--interval", "0"])) { error in
            XCTAssertEqual((error as? UsageError)?.description,
                           "Invalid value “0” for --interval: expected a number of seconds greater than 0 (fractions allowed)")
        }
        XCTAssertEqual(UsageError.hint(command: "cablescope"), "Run `cablescope --help` for usage.")
    }

    func testWatchSeparatorsAreNotChinesePunctuation() {
        CLILanguage.locale = Locale(identifier: "en")
        XCTAssertEqual(L("；"), "; ")
        XCTAssertEqual(L("、"), ", ")
        XCTAssertEqual(L("电量 %lld%% → %lld%%", 80, 81), "Battery 80% → 81%")
    }
}
