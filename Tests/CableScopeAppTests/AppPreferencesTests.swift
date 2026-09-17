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

    // MARK: - Language / Theme 解析

    func testLanguageResolvedLocale() {
        XCTAssertEqual(AppPreferences.Language.zhHans.resolvedLocale.identifier, "zh-Hans")
        XCTAssertEqual(AppPreferences.Language.english.resolvedLocale.identifier, "en")
    }

    func testThemeResolvedColorScheme() {
        XCTAssertNil(AppPreferences.Theme.system.resolvedColorScheme)
        XCTAssertEqual(AppPreferences.Theme.light.resolvedColorScheme, .light)
        XCTAssertEqual(AppPreferences.Theme.dark.resolvedColorScheme, .dark)
    }
}
