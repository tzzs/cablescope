@testable import CableScopeApp
import CableKit
import Foundation
import XCTest

final class NotificationThrottleTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    func testFlappingPortOnlyLetsFirstEventThrough() {
        var throttle = NotificationThrottle(minimumInterval: 5)
        XCTAssertTrue(throttle.allow("plug.usb-0x014", at: t0))          // 连上
        XCTAssertFalse(throttle.allow("plug.usb-0x014", at: t0 + 1))     // 抖断
        XCTAssertFalse(throttle.allow("plug.usb-0x014", at: t0 + 2))     // 抖连
        XCTAssertTrue(throttle.allow("plug.usb-0x014", at: t0 + 5))      // 窗口过后正常放行
    }

    func testRejectedEventsDoNotExtendTheWindow() {
        // 被拒的那次若刷新时间戳，持续抖动会让窗口无限顺延、永远发不出下一条。
        var throttle = NotificationThrottle(minimumInterval: 5)
        XCTAssertTrue(throttle.allow("k", at: t0))
        XCTAssertFalse(throttle.allow("k", at: t0 + 4.9))
        XCTAssertTrue(throttle.allow("k", at: t0 + 5.0))
    }

    func testKeysAreIndependent() {
        var throttle = NotificationThrottle(minimumInterval: 5)
        XCTAssertTrue(throttle.allow("plug.a", at: t0))
        XCTAssertTrue(throttle.allow("plug.b", at: t0))
        XCTAssertTrue(throttle.allow("charging", at: t0))
    }

    @MainActor
    func testWidgetOnlyRefreshesForEventsItDisplays() {
        XCTAssertTrue(WidgetRefresher.isRelevant(.sessionConnected(sessionID: "a")))
        XCTAssertTrue(WidgetRefresher.isRelevant(.sessionDisconnected(sessionID: "a")))
        XCTAssertTrue(WidgetRefresher.isRelevant(.chargingStarted))
        XCTAssertTrue(WidgetRefresher.isRelevant(.chargingStopped))
        XCTAssertFalse(WidgetRefresher.isRelevant(.ratingUpgraded(sessionID: "a", dimension: .fiveAmpConfirmed)))
    }
}
