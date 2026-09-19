import CableKit
@testable import CableScopeApp
import SwiftUI
import XCTest

/// `AppPreferences` 直接读写 `UserDefaults.standard`（未做依赖注入），
/// 每个用例执行前后备份/恢复涉及的 key，避免污染开发机的真实偏好。
final class AppPreferencesTests: XCTestCase {
    private var savedValues: [String: Any?] = [:]

    private var touchedKeys: [String] {
        [AppPreferences.notificationsEnabledKey] + AppPreferences.NotificationKind.allCases.map(\.storageKey)
    }

    override func setUp() {
        super.setUp()
        for key in touchedKeys {
            savedValues[key] = UserDefaults.standard.object(forKey: key)
        }
    }

    override func tearDown() {
        for (key, value) in savedValues {
            if let value {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        savedValues = [:]
        super.tearDown()
    }

    // MARK: - registrationDefaults

    func testRegistrationDefaultsOnlyEnablesPlugUnplugByDefault() {
        let defaults = AppPreferences.registrationDefaults

        XCTAssertEqual(defaults[AppPreferences.notificationsEnabledKey] as? Bool, true)
        XCTAssertEqual(defaults[AppPreferences.languageKey] as? String, AppPreferences.Language.system.rawValue)
        XCTAssertEqual(defaults[AppPreferences.themeKey] as? String, AppPreferences.Theme.system.rawValue)

        for kind in AppPreferences.NotificationKind.allCases {
            let expectOptedIn = kind == .plugUnplug
            XCTAssertEqual(defaults[kind.storageKey] as? Bool, expectOptedIn,
                           "\(kind) 的默认开关不符合 opt-in 规则（只有插拔通知历史上无条件开）")
        }
    }

    // MARK: - isNotificationEnabled

    func testMasterSwitchOffDisablesEveryKindRegardlessOfPerKindSetting() {
        UserDefaults.standard.set(false, forKey: AppPreferences.notificationsEnabledKey)
        UserDefaults.standard.set(true, forKey: AppPreferences.NotificationKind.chargingStarted.storageKey)

        XCTAssertFalse(AppPreferences.isNotificationEnabled(.chargingStarted))
        XCTAssertFalse(AppPreferences.isNotificationEnabled(.plugUnplug))
    }

    func testMasterSwitchOnRespectsPerKindSetting() {
        UserDefaults.standard.set(true, forKey: AppPreferences.notificationsEnabledKey)
        UserDefaults.standard.set(true, forKey: AppPreferences.NotificationKind.speedUpgraded.storageKey)
        UserDefaults.standard.set(false, forKey: AppPreferences.NotificationKind.ratingUpgraded.storageKey)

        XCTAssertTrue(AppPreferences.isNotificationEnabled(.speedUpgraded))
        XCTAssertFalse(AppPreferences.isNotificationEnabled(.ratingUpgraded))
    }

    // MARK: - 与 CableKit 共享契约的漂移守卫

    /// Widget 进程按 App 的 bundle ID 读这两项偏好，两边的 key 与 raw 值必须完全一致。
    /// 任何一侧改了字符串（改 case 名、加档位），这里立刻失败——否则表现是 widget
    /// 静默读不到偏好、悄悄退回跟随系统，没有任何报错。
    func testPreferenceKeysMatchSharedContract() {
        XCTAssertEqual(AppPreferences.languageKey, SharedAppPreferences.languageKey)
        XCTAssertEqual(AppPreferences.themeKey, SharedAppPreferences.themeKey)
    }

    func testLanguageRawValuesMatchSharedContract() {
        XCTAssertEqual(AppPreferences.Language.allCases.map(\.rawValue).sorted(),
                       SharedAppPreferences.Language.allCases.map(\.rawValue).sorted())
    }

    func testThemeRawValuesMatchSharedContract() {
        // App 侧比 CableKit 多一个 system（"跟随系统"在 CableKit 那边用 nil 表达）。
        let appThemes = Set(AppPreferences.Theme.allCases.map(\.rawValue))
        let sharedAppearances = Set(SharedAppPreferences.Appearance.allCases.map(\.rawValue))
        XCTAssertEqual(appThemes, sharedAppearances.union(["system"]))
    }

    // MARK: - Language / Theme 解析

    func testLanguageResolvedLocale() {
        XCTAssertEqual(AppPreferences.Language.zhHans.resolvedLocale.identifier, "zh-Hans")
        XCTAssertEqual(AppPreferences.Language.english.resolvedLocale.identifier, "en")
    }

    func testLanguageSystemFollowsAutoupdatingLocale() {
        // "跟随系统"必须是 autoupdatingCurrent，否则系统语言改了要重启 App 才生效。
        XCTAssertEqual(AppPreferences.Language.system.resolvedLocale, .autoupdatingCurrent)
    }

    func testThemeResolvedColorScheme() {
        XCTAssertNil(AppPreferences.Theme.system.resolvedColorScheme)
        XCTAssertEqual(AppPreferences.Theme.light.resolvedColorScheme, .light)
        XCTAssertEqual(AppPreferences.Theme.dark.resolvedColorScheme, .dark)
    }
}
