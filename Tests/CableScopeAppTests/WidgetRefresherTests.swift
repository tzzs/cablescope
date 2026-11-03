import CableKit
@testable import CableScopeApp
import XCTest

/// 小组件刷新的限流与补发规则。
///
/// 文件头承诺"窗口期内被吞掉的请求合并成窗口结束时的一次补发，保证最后一次状态
/// 变化一定会被刷到"——这是一条产品承诺，必须有测试守着，否则改坏了不会有人发现。
@MainActor
final class WidgetRefresherTests: XCTestCase {

    /// 首个相关事件立即刷新。
    func testFirstRelevantEventReloadsImmediately() {
        var reloads = 0
        let refresher = WidgetRefresher(minimumInterval: 15,
                                        bundleIdentifier: { "com.cablescope.app" },
                                        reloadTimelines: { reloads += 1 })

        refresher.handle([.chargingStarted])

        XCTAssertEqual(reloads, 1)
    }

    /// 不相关的事件（评级/速率提升）不触发刷新——WidgetKit 的重载有预算。
    func testIrrelevantEventsDoNotReload() {
        var reloads = 0
        let refresher = WidgetRefresher(minimumInterval: 15,
                                        bundleIdentifier: { "com.cablescope.app" },
                                        reloadTimelines: { reloads += 1 })

        refresher.handle([.ratingUpgraded(sessionID: "a", dimension: .fiveAmpConfirmed)])

        XCTAssertEqual(reloads, 0)
    }

    /// 没有 bundle（SwiftPM 裸可执行）时无处可刷。
    func testNoBundleIdentifierSkipsReload() {
        var reloads = 0
        let refresher = WidgetRefresher(minimumInterval: 15,
                                        bundleIdentifier: { nil },
                                        reloadTimelines: { reloads += 1 })

        refresher.handle([.chargingStarted])

        XCTAssertEqual(reloads, 0)
    }

    /// 窗口期内的请求被吞掉，并在窗口结束时补发一次——最后一次状态变化一定要刷到。
    func testTrailingReloadFiresAfterTheWindow() async throws {
        var reloads = 0
        let refresher = WidgetRefresher(minimumInterval: 0.2,
                                        bundleIdentifier: { "com.cablescope.app" },
                                        reloadTimelines: { reloads += 1 })

        refresher.handle([.chargingStarted])
        XCTAssertEqual(reloads, 1)

        refresher.handle([.chargingStopped])
        XCTAssertEqual(reloads, 1, "窗口期内的请求应被吞掉")

        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(reloads, 2, "窗口结束时应补发一次")
    }
}
