import Foundation

/// 「便宜的变化探针 + TTL 上限」读取缓存：昂贵读取只在 **key 变化** 或 **TTL 到期** 时
/// 真正执行，其余时候直接复用上一次结果。
///
/// 存在的理由：`DisplayService` / `ThunderboltService` 的数据来自 `system_profiler` 子进程
/// （实测 SPDisplaysDataType ~0.15s、SPThunderboltDataType ~0.05s），而 `CableMonitor` 每轮
/// 快照都会调用它们——菜单栏 App 常驻运行时，这两个子进程按兜底轮询间隔（1.5s）不停
/// 重启，实测持续占用约 15% 的单核。但这两类数据的变化频率远低于采样频率：
/// - 显示器：拿 `CGGetOnlineDisplayList` 的在线 ID 集合当 key（纯 CoreGraphics 调用，无子进程），
///   插拔显示器时 key 立刻变化 → 立即重读；没插拔就一直命中缓存。
/// - 雷雳：没有同等便宜可靠的变化探针（IORegistry 里的雷雳节点在无外设时行为未在真机验证过），
///   因此 key 恒定、退化为纯 TTL 语义：最坏情况下新接入的雷雳设备延迟一个 TTL 才出现。
///
/// TTL 同时是「key 没变但底层数据仍可能变」的兜底上限（例如显示器没插拔、但切换分辨率
/// 可能改变 DP 链路速率）。
///
/// 线程安全：`load` **在持锁期间执行**——这会让并发的未命中调用串行化，第二个调用者等待
/// 后直接命中刚写入的缓存，从而避免重复启动子进程（`MonitorViewModel.refresh()` 与快照流
/// 的采集循环确实可能并发）。阻塞发生在 `Task.detached` 的独立线程上，与这些 service 原本
/// 同步等待子进程退出的行为同量级，不占用协作线程池。
final class TTLCache<Key: Equatable, Value>: @unchecked Sendable {
    private let ttl: TimeInterval
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var entry: (key: Key, value: Value, timestamp: Date)?

    /// - Parameters:
    ///   - ttl: 缓存有效期上限（秒）。`<= 0` 表示禁用缓存，每次都重新读取。
    ///   - now: 当前时间的来源，注入以便单测 TTL 到期而不用真的 sleep。
    init(ttl: TimeInterval, now: @escaping @Sendable () -> Date = { Date() }) {
        self.ttl = ttl
        self.now = now
    }

    /// key 相同且未超过 TTL 时返回缓存值；否则执行 `load` 取新值、写入缓存后返回。
    func value(for key: Key, load: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }

        if ttl > 0,
           let entry,
           entry.key == key,
           now().timeIntervalSince(entry.timestamp) < ttl {
            return entry.value
        }

        let fresh = load()
        entry = (key, fresh, now())
        return fresh
    }
}
