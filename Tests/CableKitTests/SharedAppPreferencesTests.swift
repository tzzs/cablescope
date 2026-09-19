import XCTest
@testable import CableKit

/// `SharedAppPreferences` 是 App 与 Widget 之间的偏好契约。映射部分是纯函数，
/// 读取部分注入 `UserDefaults` 后同样可确定性测试（用一次性 suite，测完清掉）。
final class SharedAppPreferencesTests: XCTestCase {
    // MARK: - 语言映射

    func testLanguageRawValuesMapToExpectedLocales() {
        XCTAssertEqual(SharedAppPreferences.locale(forLanguageRawValue: "zhHans")?.identifier, "zh-Hans")
        XCTAssertEqual(SharedAppPreferences.locale(forLanguageRawValue: "english")?.identifier, "en")
    }

    func testFollowSystemInputsAllYieldNil() {
        // nil ＝ 跟随系统：调用方据此决定"不覆盖 environment"。
        XCTAssertNil(SharedAppPreferences.locale(forLanguageRawValue: "system"))
        XCTAssertNil(SharedAppPreferences.locale(forLanguageRawValue: nil))
        // 无法识别的值（未来新增档位后旧版本读到）必须安全退回跟随系统，不能崩。
        XCTAssertNil(SharedAppPreferences.locale(forLanguageRawValue: "klingon"))
        XCTAssertNil(SharedAppPreferences.locale(forLanguageRawValue: ""))
    }

    // MARK: - 主题映射

    func testThemeRawValuesMapToAppearance() {
        XCTAssertEqual(SharedAppPreferences.appearance(forThemeRawValue: "light"), .light)
        XCTAssertEqual(SharedAppPreferences.appearance(forThemeRawValue: "dark"), .dark)
    }

    func testThemeFollowSystemInputsAllYieldNil() {
        XCTAssertNil(SharedAppPreferences.appearance(forThemeRawValue: "system"))
        XCTAssertNil(SharedAppPreferences.appearance(forThemeRawValue: nil))
        XCTAssertNil(SharedAppPreferences.appearance(forThemeRawValue: "sepia"))
    }

    // MARK: - 从偏好域读取

    func testReadsValuesFromInjectedDefaults() throws {
        let suiteName = "com.cablescope.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        defaults.set("english", forKey: SharedAppPreferences.languageKey)
        defaults.set("dark", forKey: SharedAppPreferences.themeKey)

        XCTAssertEqual(SharedAppPreferences.locale(from: defaults)?.identifier, "en")
        XCTAssertEqual(SharedAppPreferences.appearance(from: defaults), .dark)
    }

    func testNilDefaultsDegradeToFollowSystem() {
        // 沙盒的 MAS 构建下读不到 App 的偏好域——此时必须安全回退成"跟随系统"，
        // 即改动前 widget 的行为，而不是崩溃或取到错误的值。
        XCTAssertNil(SharedAppPreferences.locale(from: nil))
        XCTAssertNil(SharedAppPreferences.appearance(from: nil))
    }

    func testUnsetKeysInRealDomainDegradeToFollowSystem() throws {
        let suiteName = "com.cablescope.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        // App 从未运行过 → 域存在但没有这两个 key。
        XCTAssertNil(SharedAppPreferences.locale(from: defaults))
        XCTAssertNil(SharedAppPreferences.appearance(from: defaults))
    }

    func testAppDefaultsDomainIsAddressable() {
        // 不断言能读到值（取决于开发机上 App 是否运行过），只断言按 bundle ID 打开
        // 偏好域这条路径本身可用、且读缺失 key 不崩。
        let defaults = SharedAppPreferences.appDefaults()
        XCTAssertNotNil(defaults)
        _ = SharedAppPreferences.locale(from: defaults)
    }
}
