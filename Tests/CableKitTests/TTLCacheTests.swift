import XCTest
@testable import CableKit

/// `TTLCache` 的纯逻辑测试：注入时钟，不依赖真实时间流逝，也不触发任何子进程。
final class TTLCacheTests: XCTestCase {
    /// 可推进的假时钟。
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var current = Date(timeIntervalSince1970: 0)

        var now: @Sendable () -> Date {
            { [self] in
                lock.lock()
                defer { lock.unlock() }
                return current
            }
        }

        func advance(_ seconds: TimeInterval) {
            lock.lock()
            current = current.addingTimeInterval(seconds)
            lock.unlock()
        }
    }

    func testSecondCallWithSameKeyHitsCacheAndSkipsLoad() {
        let cache = TTLCache<Int, String>(ttl: 10, now: Clock().now)
        var loadCount = 0

        XCTAssertEqual(cache.value(for: 1) { loadCount += 1; return "a" }, "a")
        XCTAssertEqual(cache.value(for: 1) { loadCount += 1; return "b" }, "a", "命中缓存时不应重新求值")
        XCTAssertEqual(loadCount, 1)
    }

    func testKeyChangeForcesReload() {
        let cache = TTLCache<Int, String>(ttl: 10, now: Clock().now)
        var loadCount = 0

        _ = cache.value(for: 1) { loadCount += 1; return "a" }
        let second = cache.value(for: 2) { loadCount += 1; return "b" }

        // key 变化（如显示器插拔导致在线 ID 集合变化）必须立即重读，不等 TTL。
        XCTAssertEqual(second, "b")
        XCTAssertEqual(loadCount, 2)
    }

    func testExpiryForcesReloadEvenWithSameKey() {
        let clock = Clock()
        let cache = TTLCache<Int, String>(ttl: 10, now: clock.now)
        var loadCount = 0

        _ = cache.value(for: 1) { loadCount += 1; return "a" }
        clock.advance(9.9)
        XCTAssertEqual(cache.value(for: 1) { loadCount += 1; return "b" }, "a", "未到期仍应命中")
        XCTAssertEqual(loadCount, 1)

        clock.advance(0.2) // 越过 TTL
        XCTAssertEqual(cache.value(for: 1) { loadCount += 1; return "c" }, "c", "到期后应重新求值")
        XCTAssertEqual(loadCount, 2)
    }

    func testExpiryIsMeasuredFromLastLoadNotFirst() {
        let clock = Clock()
        let cache = TTLCache<Int, String>(ttl: 10, now: clock.now)
        var loadCount = 0

        _ = cache.value(for: 1) { loadCount += 1; return "a" }
        clock.advance(11) // 过期 → 重读，时间戳刷新
        _ = cache.value(for: 1) { loadCount += 1; return "b" }
        clock.advance(5) // 距上次重读只过了 5s，应仍命中
        XCTAssertEqual(cache.value(for: 1) { loadCount += 1; return "c" }, "b")
        XCTAssertEqual(loadCount, 2)
    }

    func testZeroTTLDisablesCaching() {
        let cache = TTLCache<Int, String>(ttl: 0, now: Clock().now)
        var loadCount = 0

        _ = cache.value(for: 1) { loadCount += 1; return "a" }
        _ = cache.value(for: 1) { loadCount += 1; return "b" }
        XCTAssertEqual(loadCount, 2, "TTL <= 0 应等价于不缓存")
    }

    func testConcurrentMissesLoadOnlyOnce() {
        let cache = TTLCache<Int, String>(ttl: 60, now: Clock().now)
        let loadCount = NSLock.Counter()

        // load 在持锁期间执行 → 并发未命中会串行化，后到者直接命中刚写入的值。
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            _ = cache.value(for: 1) {
                loadCount.increment()
                return "a"
            }
        }
        XCTAssertEqual(loadCount.value, 1, "并发未命中不应重复触发昂贵读取")
    }
}

private extension NSLock {
    /// 线程安全的计数器（只为上面的并发用例服务）。
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func increment() {
            lock.lock()
            count += 1
            lock.unlock()
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }
}
