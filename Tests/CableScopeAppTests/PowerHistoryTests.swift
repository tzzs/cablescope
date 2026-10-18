@testable import CableScopeApp
import Foundation
import XCTest

@MainActor
final class PowerHistoryTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    func testCapacityDropsOldestSamples() {
        let history = PowerHistory()
        for i in 0..<(PowerHistory.capacity + 5) {
            history.append(watts: Double(i), at: t0.addingTimeInterval(Double(i)))
        }
        XCTAssertEqual(history.points.count, PowerHistory.capacity)
        XCTAssertEqual(history.points.first?.watts, 5)
    }

    func testNaNSplitsSegments() {
        let history = PowerHistory()
        [10, 12, .nan, .nan, 30].enumerated().forEach { i, w in
            history.append(watts: w, at: t0.addingTimeInterval(Double(i)))
        }
        XCTAssertEqual(history.segments.map { $0.map(\.watts) }, [[10, 12], [30]])
    }

    func testAllZeroIsNotWorthCharting() {
        let history = PowerHistory()
        history.append(watts: 0, at: t0)
        history.append(watts: .nan, at: t0 + 1)
        XCTAssertFalse(history.hasNonZeroPower)
        history.append(watts: 5, at: t0 + 2)
        XCTAssertTrue(history.hasNonZeroPower)
    }
}
