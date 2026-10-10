import Foundation

/// 按 key 的最小间隔限流（纯值类型，可单测）。
///
/// 用途：线头松动 / 接触不良时，同一个口会在几秒内反复"连上—断开—连上"，每次都弹
/// 一条横幅就是刷屏。插拔两类事件共用同一个 key（`plug.<sessionID>`），所以抖动产生的
/// 交替 connect/disconnect 也只放过第一条；充电开始/停止同理共用 `charging`。
struct NotificationThrottle {
    var minimumInterval: TimeInterval
    private var lastAllowed: [String: Date] = [:]

    init(minimumInterval: TimeInterval) {
        self.minimumInterval = minimumInterval
    }

    /// 允许则记下时间并返回 true；距离上次放行不足 `minimumInterval` 返回 false
    /// （被拒的这次不刷新时间戳，否则持续抖动会让窗口无限顺延、永远发不出下一条）。
    mutating func allow(_ key: String, at now: Date = Date()) -> Bool {
        if let last = lastAllowed[key], now.timeIntervalSince(last) < minimumInterval {
            return false
        }
        lastAllowed[key] = now
        return true
    }
}
