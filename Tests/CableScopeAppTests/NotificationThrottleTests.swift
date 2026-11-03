@testable import CableScopeApp
import CableKit
import Foundation
import XCTest

final class NotificationThrottleTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    /// 同一方向抖动被抑制；反向事件独立放行。
    func testFlappingPortIsThrottledPerDirection() {
        var throttle = NotificationThrottle(minimumInterval: 5)
        XCTAssertTrue(throttle.allow("plug.in.usb-0x014", at: t0))          // 连上
        XCTAssertTrue(throttle.allow("plug.out.usb-0x014", at: t0 + 1))     // 抖断：反方向，独立放行
        XCTAssertFalse(throttle.allow("plug.in.usb-0x014", at: t0 + 2))     // 抖连：同方向，窗口内
        XCTAssertFalse(throttle.allow("plug.out.usb-0x014", at: t0 + 3))    // 抖断：同方向，窗口内
        XCTAssertTrue(throttle.allow("plug.in.usb-0x014", at: t0 + 5))      // 窗口过后正常放行
    }

    /// 回归：拔线后几秒内插回，插线通知不能被拔线的时间戳吞掉。
    ///
    /// 实测现场（系统电源日志）：04:18:09 拔线 → 04:18:13 插线。旧实现两个方向共用
    /// `plug.<sessionID>`，插线距拔线只有 4 秒，被 5 秒窗口直接丢弃，用户看到的就是
    /// 「只有拔出有提示」。这里钉住两个方向 key 必须不同。
    func testQuickReplugNotifiesBothDirections() {
        var throttle = NotificationThrottle(minimumInterval: 5)
        let unplug = NotificationController.throttleKey(for: .sessionDisconnected(sessionID: "Port-USB-C@2"))
        let plug = NotificationController.throttleKey(for: .sessionConnected(sessionID: "Port-USB-C@2"))

        XCTAssertNotEqual(unplug, plug, "插线与拔线不能共用限流 key")
        XCTAssertTrue(throttle.allow(unplug, at: t0))
        XCTAssertTrue(throttle.allow(plug, at: t0 + 4), "拔线 4 秒后的插线通知必须放行")
    }

    /// 充电开始/停止同理，方向独立。
    func testChargingStartAndStopUseIndependentKeys() {
        XCTAssertNotEqual(NotificationController.throttleKey(for: .chargingStarted),
                          NotificationController.throttleKey(for: .chargingStopped))
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
