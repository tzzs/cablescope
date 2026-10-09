@testable import CableScopeApp
import Foundation
import XCTest

/// 启动时是否拉起主窗口：首次启动必开，之后按偏好；用独立 suite，不碰真实偏好。
final class LaunchDecisionTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "LaunchDecisionTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.register(defaults: [AppPreferences.openMainWindowOnLaunchKey: true])
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testFirstLaunchAlwaysOpensEvenWhenPreferenceIsOff() {
        XCTAssertTrue(AppPreferences.shouldOpenMainWindowOnLaunch(isFirstLaunch: true, preference: false))
    }

    func testLaterLaunchesFollowPreference() {
        XCTAssertTrue(AppPreferences.shouldOpenMainWindowOnLaunch(isFirstLaunch: false, preference: true))
        XCTAssertFalse(AppPreferences.shouldOpenMainWindowOnLaunch(isFirstLaunch: false, preference: false))
    }

    func testConsumeMarksFirstLaunchAsUsed() {
        defaults.set(false, forKey: AppPreferences.openMainWindowOnLaunchKey)
        XCTAssertTrue(AppPreferences.consumeLaunchDecision(defaults), "首次启动无视偏好")
        XCTAssertFalse(AppPreferences.consumeLaunchDecision(defaults), "第二次起按偏好（关）")
    }

    func testDefaultPreferenceKeepsPreviousAlwaysOpenBehavior() {
        _ = AppPreferences.consumeLaunchDecision(defaults)
        XCTAssertTrue(AppPreferences.consumeLaunchDecision(defaults), "偏好默认开，老用户行为不变")
        XCTAssertEqual(AppPreferences.registrationDefaults[AppPreferences.openMainWindowOnLaunchKey] as? Bool, true)
    }
}
