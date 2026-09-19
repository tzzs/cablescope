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
}
