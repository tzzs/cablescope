import Foundation

/// 按 key 的最小间隔限流（纯值类型，可单测）。
///
/// 用途：线头松动 / 接触不良时，同一个口会在几秒内反复"连上—断开—连上"，每次都弹
/// 一条横幅就是刷屏。限流 key **按事件方向区分**（`plug.in.<sessionID>` /
/// `plug.out.<sessionID>`，见 `NotificationController.throttleKey(for:)`）：同向抖动
/// 每 5 秒只放过一条，而"拔下后马上插回"是两个方向，插线不会被拔线的时间戳挡掉。
/// 早前两个方向共用一个 key，结果拔线后 5 秒内的插线通知被静默吞掉——那正是"只有
/// 拔出有提示、插进没提示"的成因。
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
