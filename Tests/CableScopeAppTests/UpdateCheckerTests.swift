@testable import CableScopeApp
import XCTest

final class UpdateCheckerTests: XCTestCase {
    func testNoUpdateWhenCurrentIsNil() {
        XCTAssertFalse(UpdateChecker.isUpdateAvailable(current: nil, latest: "1.0.0"))
    }

    func testNoUpdateWhenVersionsAreEqual() {
        XCTAssertFalse(UpdateChecker.isUpdateAvailable(current: "1.2.3", latest: "1.2.3"))
    }

    func testUpdateAvailableWhenLatestPatchIsGreater() {
        XCTAssertTrue(UpdateChecker.isUpdateAvailable(current: "1.2.3", latest: "1.2.4"))
    }

    func testUpdateAvailableWhenLatestMajorIsGreater() {
        XCTAssertTrue(UpdateChecker.isUpdateAvailable(current: "1.9.9", latest: "2.0.0"))
    }

    func testNoUpdateWhenCurrentIsNewer() {
        XCTAssertFalse(UpdateChecker.isUpdateAvailable(current: "2.0.0", latest: "1.9.9"))
    }

    func testVersionPrefixVIsTolerated() {
        XCTAssertTrue(UpdateChecker.isUpdateAvailable(current: "v1.0.0", latest: "v1.0.1"))
    }

    func testPrereleaseSuffixIsIgnoredForComparison() {
        XCTAssertTrue(UpdateChecker.isUpdateAvailable(current: "1.0.0", latest: "1.0.1-beta"))
        XCTAssertFalse(UpdateChecker.isUpdateAvailable(current: "1.0.1", latest: "1.0.1-beta"))
    }

    func testMalformedCurrentVersionNeverPromptsDevBuilds() {
        // 开发版（非语义化版本号）不应被打扰。
        XCTAssertFalse(UpdateChecker.isUpdateAvailable(current: "dev", latest: "1.0.0"))
        XCTAssertFalse(UpdateChecker.isUpdateAvailable(current: "1.0", latest: "1.0.1"))
    }

    func testMalformedLatestVersionYieldsNoUpdate() {
        XCTAssertFalse(UpdateChecker.isUpdateAvailable(current: "1.0.0", latest: "not-a-version"))
    }

    // MARK: - 安装渠道

    func testFormulaKegPathIsDetectedFromResolvedPath() {
        let channel = UpdateChecker.installChannel(
            resolvedBundlePath: "/opt/homebrew/Cellar/cablescope-app/0.5.0/CableScope.app",
            caskroomExists: { _ in false })
        XCTAssertEqual(channel, .homebrewFormula)
        XCTAssertEqual(channel.upgradeCommand, "brew upgrade cablescope-app")
    }

    func testCaskIsDetectedFromCaskroomRecord() {
        let channel = UpdateChecker.installChannel(
            resolvedBundlePath: "/Applications/CableScope.app",
            caskroomExists: { $0 == "/usr/local/Caskroom/cablescope" })
        XCTAssertEqual(channel, .homebrewCask)
        XCTAssertEqual(channel.upgradeCommand, "brew upgrade --cask cablescope")
    }

    func testPlainDMGInstallHasNoUpgradeCommand() {
        let channel = UpdateChecker.installChannel(resolvedBundlePath: "/Applications/CableScope.app",
                                                   caskroomExists: { _ in false })
        XCTAssertEqual(channel, .direct)
        XCTAssertNil(channel.upgradeCommand)
    }

    // MARK: - 自动检查节流

    func testAutomaticCheckIsDueOncePerDay() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(UpdateChecker.isAutomaticCheckDue(lastCheck: nil, now: now))
        XCTAssertFalse(UpdateChecker.isAutomaticCheckDue(lastCheck: now.addingTimeInterval(-3600), now: now))
        XCTAssertTrue(UpdateChecker.isAutomaticCheckDue(lastCheck: now.addingTimeInterval(-86_400), now: now))
    }

    func testSameVersionIsOnlyAnnouncedOnceAutomatically() {
        XCTAssertTrue(UpdateChecker.shouldNotifyAutomatically(latest: "v0.6.0", lastNotified: nil))
        XCTAssertFalse(UpdateChecker.shouldNotifyAutomatically(latest: "v0.6.0", lastNotified: "v0.6.0"))
        XCTAssertTrue(UpdateChecker.shouldNotifyAutomatically(latest: "v0.7.0", lastNotified: "v0.6.0"))
    }

    func testAutomaticCheckIsOffByDefault() {
        XCTAssertEqual(AppPreferences.registrationDefaults[UpdateChecker.autoCheckKey] as? Bool, false)
    }
}
