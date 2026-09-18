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

    func testChineseLocaleFallsBackToSourceKey() {
        // zh-Hans 是源语言，没有独立 lproj：按设计安全回退为 key 本身（即中文原文）。
        let key = "线缆已断开"
        XCTAssertEqual(AppLocalization.string(key, locale: chinese), key)
    }

    func testUnknownKeyFallsBackToKeyItself() {
        let key = "这条文案不存在于任何译文表中"
        XCTAssertEqual(AppLocalization.string(key, locale: english), key)
    }
}
