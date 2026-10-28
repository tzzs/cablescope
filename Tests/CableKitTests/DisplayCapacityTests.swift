import XCTest
@testable import CableKit

/// 显示器缓冲扩容策略的测试。
///
/// `CGGetOnlineDisplayList(maxDisplays, ...)` 的 `maxDisplays` 是**入参上限**
/// （CoreGraphics 头文件："no more than maxDisplays will be stored"），所以返回的
/// `count` 恒 ≤ `maxDisplays`。这意味着**扩容必须由旧容量倍增得到**——若用 `count`
/// 决定新容量，就是恒等赋值，循环永不收敛、整机挂死。
///
/// 这条策略若写成非纯函数就无法单测：CI runner 只有 1 台显示器，那条死循环在 CI 上
/// 永远不会暴露。抽成纯函数后，这里用模拟的 CoreGraphics 语义把它钉住。
final class DisplayCapacityTests: XCTestCase {
    /// 模拟 CoreGraphics 的截断语义：实际有 `actual` 台在线，缓冲区容量 `capacity`，
    /// 返回的 count = min(actual, capacity)。
    private func simulate(actual: UInt32, capacity: UInt32, maxCapacity: UInt32) -> (ids: [UInt32], iterations: Int) {
        var cap = capacity
        var iterations = 0
        while true {
            iterations += 1
            XCTAssertLessThan(iterations, 10, "扩容循环必须在有限步内收敛（不得死循环）")
            let count = min(actual, cap)
            if count < cap {
                return (Array(0..<count), iterations)
            }
            guard let next = DisplayService.nextCapacity(capacity: cap, maxCapacity: maxCapacity) else {
                return (Array(0..<cap), iterations)
            }
            cap = next
        }
    }

    /// 常规场景（≤16 台）第一次就装下，不该扩容。
    func testSmallDisplayCountDoesNotExpand() {
        let result = simulate(actual: 2, capacity: 16, maxCapacity: 64)
        XCTAssertEqual(result.ids, [0, 1])
        XCTAssertEqual(result.iterations, 1, "装得下就不该重试")
    }

    /// 刚好 16 台：触顶，扩容到 32 后装下。
    func testExactlyFullBufferExpandsOnce() {
        let result = simulate(actual: 16, capacity: 16, maxCapacity: 64)
        XCTAssertEqual(result.ids.count, 16)
        XCTAssertEqual(result.iterations, 2, "16 台 → 扩容到 32 → 一次装下")
    }

    /// 20 台（正是死循环 bug 的触发场景）：必须收敛并返回全部 20 台。
    func testTwentyDisplaysConverges() {
        let result = simulate(actual: 20, capacity: 16, maxCapacity: 64)
        XCTAssertEqual(result.ids.count, 20, "20 台显示器必须全部报出")
        XCTAssertLessThanOrEqual(result.iterations, 3, "16 → 32 → 装下")
    }

    /// 64 台：触到上限后停止扩容，返回已知的那部分（不无限增长内存）。
    func testStopsAtMaxCapacity() {
        let result = simulate(actual: 100, capacity: 16, maxCapacity: 64)
        XCTAssertEqual(result.ids.count, 64, "达上限后用已知的 64 个")
        XCTAssertLessThanOrEqual(result.iterations, 4, "16 → 32 → 64 → 停止")
    }

    // MARK: - 纯函数本身

    /// 容量翻倍，且不超过上限。
    func testNextCapacityDoubles() {
        XCTAssertEqual(DisplayService.nextCapacity(capacity: 16, maxCapacity: 64), 32)
        XCTAssertEqual(DisplayService.nextCapacity(capacity: 32, maxCapacity: 64), 64)
    }

    /// 逼近上限时取上限本身，不越界。
    func testNextCapacityClampedToMax() {
        XCTAssertEqual(DisplayService.nextCapacity(capacity: 48, maxCapacity: 64), 64)
    }

    /// 已达上限 → nil（停止扩容）。
    func testNextCapacityNilAtMax() {
        XCTAssertNil(DisplayService.nextCapacity(capacity: 64, maxCapacity: 64))
    }

    /// 关键不变式：新容量必须**严格大于**旧容量。
    ///
    /// 若实现误用 `count`（CoreGraphics 保证 `count <= capacity`）决定新容量，
    /// 就会得到恒等赋值 → 死循环。这条断言直接钉住那个 bug。
    func testNextCapacityAlwaysStrictlyGrows() {
        for capacity in UInt32(1)...64 {
            guard let next = DisplayService.nextCapacity(capacity: capacity, maxCapacity: 64) else {
                continue
            }
            XCTAssertGreaterThan(next, capacity, "容量必须严格增长，否则循环不收敛（count 恒 ≤ capacity）")
        }
    }
}
