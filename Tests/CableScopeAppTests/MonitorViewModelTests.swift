import CableKit
@testable import CableScopeApp
import XCTest

/// 用真实 `CableMonitor` 对真机做一次性快照（同 `RealEnvironmentSmokeTests` 的哲学）：
/// 是否插着线缆不影响下面的断言，只验证 `MonitorViewModel` 派生状态之间的内部一致性，
/// 以及评级历史确实落到了注入路径（不触碰真实用户的
/// ~/Library/Application Support/CableScope/ratings.json）。
@MainActor
final class MonitorViewModelTests: XCTestCase {
    private var ratingsURL: URL!

    override func setUp() {
        super.setUp()
        ratingsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cablescope-test-ratings-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: ratingsURL)
        ratingsURL = nil
        super.tearDown()
    }

    func testInitialStateHasNoSnapshotOrSessions() {
        let viewModel = MonitorViewModel(monitor: CableMonitor(), ratingsURL: ratingsURL)

        XCTAssertNil(viewModel.snapshot)
        XCTAssertTrue(viewModel.sessions.isEmpty)
        XCTAssertNil(viewModel.selectedSession)
        XCTAssertFalse(viewModel.isRefreshing)
        // 注入路径尚不存在文件时，engine 从空白状态起步——不会读到真实用户的评级历史。
        XCTAssertEqual(viewModel.rating, CableRatingEngine().overallRating())
    }

    func testRefreshIngestsSnapshotAndPersistsToInjectedPath() async throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: ratingsURL.path))

        let viewModel = MonitorViewModel(monitor: CableMonitor(), ratingsURL: ratingsURL)
        viewModel.refresh()
        XCTAssertTrue(viewModel.isRefreshing, "refresh() 应同步置位 isRefreshing，再异步采集")

        try await waitUntil(seconds: 15) { !viewModel.isRefreshing }

        XCTAssertNotNil(viewModel.snapshot,
                        "真实 CableMonitor 的 snapshotNow() 不应返回 nil——无设备时也应降级为空快照而非失败")
        // 未显式选择会话时回退到第一根（或都为空）。
        XCTAssertEqual(viewModel.selectedSession?.id, viewModel.sessions.first?.id)
        // ingest 会在每次快照后保存一次评级历史；验证它确实落到了注入路径，而不是真实用户的
        // ratings.json（回归此前 init 里"加载走 canonical、保存走注入路径"的不一致问题）。
        XCTAssertTrue(FileManager.default.fileExists(atPath: ratingsURL.path))
    }

    // MARK: - 轮询等待（refresh() 不返回可 await 的句柄，用超时轮询代替）

    private func waitUntil(seconds: TimeInterval, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("等待超时（\(seconds)s）")
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
