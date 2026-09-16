import Foundation

// MARK: - 线缆变化通知事件推断（纯函数，可单测）
//
// 目标：把"这一次快照 vs 上一次快照"翻译成"发生了什么值得通知的事"——插拔、
// 开始/停止充电、协商速率提升、评级提升。只产出语义事件，不生成文案（文案按当前
// 语言在 App 层/`NotificationController` 生成），也不管用户开关（那是
// `AppPreferences.isNotificationEnabled` 的事）。

/// 可通知的线缆/整机事件。
public enum CableNotificationEvent: Equatable, Sendable {
    case sessionConnected(sessionID: String)
    case sessionDisconnected(sessionID: String)
    /// 整机级别：只有一路电源，不按 session 归属（避免虚假精度）。
    case chargingStarted
    case chargingStopped
    case usbSpeedUpgraded(sessionID: String, to: USBSpeed)
    case ratingUpgraded(sessionID: String, dimension: RatingUpgradeDimension)
}

/// "评级提升"的具体维度——不能用 `CableRating` 整体 `!=` 比较，`sampleCount`/`lastSeen`
/// 每次采样都变，会导致几乎每次 ingest 都误判为"提升"。这里只挑真正代表"能力变强"的维度。
public enum RatingUpgradeDimension: Equatable, Sendable {
    case fiveAmpConfirmed
    case displayLink
}

/// 上一次观测的精简状态，只保留 diff 需要的字段（不是整份 `CableSnapshot`）。
public struct NotificationBaseline: Equatable, Sendable {
    public var sessionIDs: Set<String>
    public var isCharging: Bool
    public var ratingBySession: [String: CableRating]

    public init(sessionIDs: Set<String> = [],
                isCharging: Bool = false,
                ratingBySession: [String: CableRating] = [:]) {
        self.sessionIDs = sessionIDs
        self.isCharging = isCharging
        self.ratingBySession = ratingBySession
    }
}

public enum NotificationDiff {
    /// - Parameters:
    ///   - baseline: 上一次 diff 返回的基线；`nil` 视为冷启动，只建立基线、不产生任何
    ///     事件——这条规则同时覆盖"插拔首个快照不通知"的现状和"新事件类型冷启动
    ///     不该狂发"的要求，不需要为新事件类型单独写特殊分支。
    ///   - snapshot: 当前快照。
    ///   - ratingEngine: 已经 record 过本次快照的评级引擎（取记录后的最新评级）。
    /// - Returns: 本次产生的事件（顺序稳定，便于单测），以及供下一次调用使用的新基线。
    public static func diff(baseline: NotificationBaseline?,
                            snapshot: CableSnapshot,
                            ratingEngine: CableRatingEngineProtocol) -> (events: [CableNotificationEvent],
                                                                         baseline: NotificationBaseline) {
        let currentIDs = Set(snapshot.sessions.map(\.id))
        let currentRatings = Dictionary(uniqueKeysWithValues: snapshot.sessions.compactMap { session in
            ratingEngine.rating(forSessionID: session.id).map { (session.id, $0) }
        })
        let isCharging = snapshot.power?.isCharging ?? false
        let newBaseline = NotificationBaseline(sessionIDs: currentIDs, isCharging: isCharging,
                                               ratingBySession: currentRatings)

        guard let baseline else {
            return ([], newBaseline)
        }

        var events: [CableNotificationEvent] = []

        // 插拔：按 snapshot.sessions 现有顺序报"新增"，按 id 排序报"移除"（baseline 只存
        // Set，没有顺序信息可沿用），保证同一输入下事件顺序稳定、便于断言。
        for session in snapshot.sessions where !baseline.sessionIDs.contains(session.id) {
            events.append(.sessionConnected(sessionID: session.id))
        }
        for id in baseline.sessionIDs.subtracting(currentIDs).sorted() {
            events.append(.sessionDisconnected(sessionID: id))
        }

        if isCharging != baseline.isCharging {
            events.append(isCharging ? .chargingStarted : .chargingStopped)
        }

        for session in snapshot.sessions {
            guard let rating = currentRatings[session.id],
                  let previous = baseline.ratingBySession[session.id] else { continue } // 新会话已有 sessionConnected，不重复报"提升"
            if let bps = rating.maxUSBBitsPerSecond, bps > (previous.maxUSBBitsPerSecond ?? 0) {
                events.append(.usbSpeedUpgraded(sessionID: session.id, to: USBSpeed(bitsPerSecond: bps)))
            }
            if rating.is5ACable, !previous.is5ACable {
                events.append(.ratingUpgraded(sessionID: session.id, dimension: .fiveAmpConfirmed))
            }
            if let hz = rating.maxRefreshRateHz, hz > (previous.maxRefreshRateHz ?? 0) {
                events.append(.ratingUpgraded(sessionID: session.id, dimension: .displayLink))
            }
        }

        return (events, newBaseline)
    }
}
