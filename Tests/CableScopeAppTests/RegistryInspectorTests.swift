import XCTest
@testable import CableScopeApp

/// IOKit 属性检查器的异步结果归属判定。
///
/// 回归背景：切换类名会取消旧的 SwiftUI task，但 `RegistryService` 的 detached 枚举
/// 不可取消、仍会返回。返回后若不加判断就写界面状态，旧类名的条目会覆盖新类名的列表
/// ——侧栏写着 `AppleHPM`，列表却是 `IOUSBHostDevice` 的条目。
final class RegistryInspectorTests: XCTestCase {
    func testResultIsCurrentWhenClassMatchesAndNotCancelled() {
        XCTAssertFalse(RegistryInspectorView.isStaleResult(requestedClass: "AppleHPM",
                                                           currentClass: "AppleHPM",
                                                           isCancelled: false))
    }

    func testResultIsStaleAfterClassSwitch() {
        XCTAssertTrue(RegistryInspectorView.isStaleResult(requestedClass: "IOUSBHostDevice",
                                                          currentClass: "AppleHPM",
                                                          isCancelled: false))
    }

    func testResultIsStaleWhenTaskCancelled() {
        XCTAssertTrue(RegistryInspectorView.isStaleResult(requestedClass: "AppleHPM",
                                                          currentClass: "AppleHPM",
                                                          isCancelled: true))
    }

    func testResultIsStaleWhenBothChangedAndCancelled() {
        XCTAssertTrue(RegistryInspectorView.isStaleResult(requestedClass: "IOUSBHostDevice",
                                                          currentClass: "AppleHPM",
                                                          isCancelled: true))
    }
}
