@testable import CableScopeApp
import XCTest

/// 回归测试：App 层英文文案必须真的能查到译文。
///
/// 背景：经典 SwiftPM 构建引擎（CI 在用）不把 `.xcstrings` 编译成 `.strings`，只原样
/// 拷贝 JSON，导致 `en.lproj` 永远不存在、英文全部退化成中文 key，而打包脚本平铺
/// `*.lproj` 的步骤会静默跳过——整条链路不报任何错。CableKit 侧是靠 `DiagnosticsTests`
/// 的英文断言暴露的（5401f72），App 侧当时没有对应断言所以漏了。这组用例就是补上
/// 那个缺失的断言：只要英文表没被正确编译/拷贝进资源 bundle，这里立刻失败。
final class AppLocalizationTests: XCTestCase {
    private let english = Locale(identifier: "en")
    private let chinese = Locale(identifier: "zh-Hans")

    func testEnglishLookupReturnsTranslationNotChineseKey() {
        let key = "线缆已断开"
        let translated = AppLocalization.string(key, locale: english)

        XCTAssertNotEqual(translated, key,
                          "英文查表退回了中文 key——资源 bundle 里很可能没有 en.lproj（.xcstrings 未被编译）")
        XCTAssertEqual(translated, "Cable Disconnected")
    }

    func testTemplateStringKeepsFormatPlaceholder() {
        // 带 %@ 占位符的模板必须原样保留占位符，否则 String(format:) 会拼不出内容。
        let translated = AppLocalization.string("已连接 %@", locale: english)
        XCTAssertTrue(translated.contains("%@"), "模板译文丢了 %@ 占位符：\(translated)")
        XCTAssertNotEqual(translated, "已连接 %@")
    }

    /// 这一批 key 是"补漏那一轮"加进去的：它们的调用点都走 SwiftUI 的
    /// `Text`/`Label`（LocalizedStringKey），漏翻时只是静静显示中文，不报任何错。
    /// `scripts/check_localization.py` 在源码层守住"表里有没有这条"，这里守的是
    /// 另一半——译文表有没有真的被编译/拷贝进运行期的资源 bundle。
    func testPreviouslyUntranslatedKeysResolve() {
        let expected = [
            "最近快照 %@": "Last snapshot %@",
            "PD 档位（%@）": "PD Tiers (%@)",
            "e-marker 未上报厂商": "e-marker did not report a vendor",
            "对端 VID %@": "Partner VID %@",
            "e-marker 厂商 %@": "e-marker vendor %@",
            "类 %@ · registryID %llu · %lld 个属性": "Class %@ · registryID %llu · %lld properties",
            "首次确认支持 5A": "5A support confirmed for the first time",
            "显示器链路规格提升": "Display link spec upgraded",
        ]
        for (key, english) in expected {
            XCTAssertEqual(AppLocalization.string(key, locale: self.english), english,
                           "「\(key)」的英文查表失败")
        }
    }

    func testChineseLocaleFallsBackToSourceKey() {
        // zh-Hans 是源语言，没有独立 lproj：按设计安全回退为 key 本身（即中文原文）。
        let key = "线缆已断开"
        XCTAssertEqual(AppLocalization.string(key, locale: chinese), key)
    }

    func testUnknownKeyFallsBackToKeyItself() {
        let key = "这条文案不存在于任何译文表中"
        XCTAssertEqual(AppLocalization.string(key, locale: english), key)
    }

    /// 复数走 `en.lproj/Localizable.stringsdict`：此前 `.strings` 里只能写成 "%lld device(s)"、
    /// "%lld times"，于是界面上出现 "1 times"、"Battery Cycles 47 times"。`.stringsdict`
    /// 是 plist，两种 SwiftPM 构建引擎都原样拷贝（不像 `.xcstrings` 需要编译），这里断言
    /// 它真的进了运行期资源包，且 one/other 两个分支都能选中。
    func testPluralRulesResolveFromStringsdict() {
        func plural(_ key: String, _ n: Int) -> String {
            AppLocalization.format(key, locale: english, n)
        }
        XCTAssertEqual(plural("%lld 台设备", 1), "1 device")
        XCTAssertEqual(plural("%lld 台设备", 3), "3 devices")
        XCTAssertEqual(plural("%lld 次", 1), "1 cycle")
        XCTAssertEqual(plural("%lld 次", 47), "47 cycles")
        XCTAssertEqual(plural("累计连接 %lld 次", 1), "Connected once")
        XCTAssertEqual(plural("累计连接 %lld 次", 12), "Connected 12 times")
        XCTAssertEqual(plural("整机评级 · %lld 次观测", 2), "System rating · 2 observations")
        // 复数分支必须跟随请求的语言，而不是系统语言（中文系统下曾一律落进 other）。
        XCTAssertEqual(String(format: AppLocalization.string("%lld 台设备", locale: english),
                              locale: Locale(identifier: "zh-Hans"), 1), "1 devices",
                       "对照组：按中文 locale 格式化就会选错分支，这正是 format(_:locale:) 存在的理由")
    }
}
