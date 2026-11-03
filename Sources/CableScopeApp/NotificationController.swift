import CableKit
import Foundation
@preconcurrency import UserNotifications

/// 线缆变化通知：插拔 + "线缆插着不动但状态变了"（开始/停止充电、协商速率提升、
/// 评级提升）。事件本身由 `CableKit.NotificationDiff`（纯函数，可单测）推断，这里只管
/// "要不要发"（按 `AppPreferences` 的总开关/细分开关）和"怎么发"（`UNUserNotificationCenter`）。
///
/// - 冷启动（首个快照）不产生任何事件，规则在 `NotificationDiff` 里，这里不用特殊处理；
/// - **限流按「事件方向」分 key**（`plug.in.<id>` / `plug.out.<id>`、`charging.start` /
///   `charging.stop`），同一方向 5 秒内只放行一次。共用 key 会让「拔下后马上插回」这种
///   最常见的测试/使用动作被拔线的时间戳吞掉——实测电源日志 04:18:09 拔、04:18:13 插，
///   插线通知因距拔线不足 5 秒被静默丢弃，用户看到的就是「只有拔出有提示」。按方向分 key
///   后，接触不良的抖动仍然被限制在每 5 秒每个方向最多一条，不会刷屏；
/// - 通知授权懒请求（首次真正要发时才问）；不满足 `NotificationAvailability.isAvailable`
///   时静默禁用（SwiftPM 裸可执行、或未签名调试构建——两者都会让
///   `UNUserNotificationCenter.current()` 崩掉整个进程，详见该类型的注释）。
@MainActor
final class NotificationController {
    private var baseline: NotificationBaseline?
    /// 上一轮快照的会话：断开事件发生时会话已不在当前快照里，得从这里取端口名，
    /// 通知才能说清"哪个口断开了"，而不是笼统的"拔出了 1 根线缆"。
    private var previousSessions: [String: CableSession] = [:]
    private var throttle = NotificationThrottle(minimumInterval: 5)
    private var hasRequestedAuthorization = false
    private let widgetRefresher = WidgetRefresher()

    nonisolated static func activate() {
        guard NotificationAvailability.isAvailable else { return }
        // 前台（菜单栏形态常驻前台上下文）也要弹横幅，而不是静默入中心。
        UNUserNotificationCenter.current().delegate = ForegroundPresenter.shared
    }

    /// 限流 key：**按事件方向区分**。
    ///
    /// 插线与拔线是两个独立事实，共用一个 key 会让「拔下后几秒内插回」的插线通知被拔线
    /// 的时间戳挡掉（`NotificationThrottle` 只认 key，不认方向）。分 key 之后同向抖动仍
    /// 被 5 秒窗口抑制，反向事件互不影响。
    nonisolated static func throttleKey(for event: CableNotificationEvent) -> String {
        switch event {
        case .sessionConnected(let sessionID): return "plug.in.\(sessionID)"
        case .sessionDisconnected(let sessionID): return "plug.out.\(sessionID)"
        case .chargingStarted: return "charging.start"
        case .chargingStopped: return "charging.stop"
        case .usbSpeedUpgraded(let sessionID, _): return "speed.\(sessionID)"
        case .ratingUpgraded(let sessionID, _): return "rating.\(sessionID)"
        }
    }

    func process(snapshot: CableSnapshot,
                ratingEngine: CableRatingEngineProtocol,
                port: @escaping (CableSession) -> USBCPortSnapshot?) {
        let (events, newBaseline) = NotificationDiff.diff(baseline: baseline, snapshot: snapshot,
                                                           ratingEngine: ratingEngine)
        baseline = newBaseline
        let lastSessions = previousSessions
        previousSessions = Dictionary(snapshot.sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard !events.isEmpty else { return }

        // 小组件刷新与通知开关无关（关了通知的用户也希望小组件是新的），放在可用性判断之前。
        widgetRefresher.handle(events)

        guard NotificationAvailability.isAvailable else { return }
        let locale = AppPreferences.effectiveLocale()
        for event in events {
            deliver(for: event, snapshot: snapshot, previousSessions: lastSessions, port: port, locale: locale)
        }
    }

    private func deliver(for event: CableNotificationEvent,
                         snapshot: CableSnapshot,
                         previousSessions: [String: CableSession],
                         port: @escaping (CableSession) -> USBCPortSnapshot?,
                         locale: Locale) {
        let kind: AppPreferences.NotificationKind
        // 插拔与充电状态变化会连着抖，按方向限流；速率/评级提升是低频事件，不限流。
        let isThrottled: Bool
        switch event {
        case .sessionConnected, .sessionDisconnected:
            kind = .plugUnplug
            isThrottled = true
        case .chargingStarted:
            kind = .chargingStarted
            isThrottled = true
        case .chargingStopped:
            kind = .chargingStopped
            isThrottled = true
        case .usbSpeedUpgraded:
            kind = .speedUpgraded
            isThrottled = false
        case .ratingUpgraded:
            kind = .ratingUpgraded
            isThrottled = false
        }

        guard AppPreferences.isNotificationEnabled(kind) else { return }
        // 先确认要发的会话存在，再消耗限流窗口——否则一次查不到会话的失败
        // 也会占掉这个方向 5 秒的额度。
        guard let draft = NotificationComposer.draft(for: event,
                                                     snapshot: snapshot,
                                                     previousSessions: previousSessions,
                                                     port: port,
                                                     locale: locale) else { return }
        if isThrottled, !throttle.allow(Self.throttleKey(for: event)) { return }
        deliver(draft)
    }

    private func deliver(_ draft: NotificationDraft) {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = draft.title
        content.body = draft.body
        content.threadIdentifier = draft.thread
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)

        // 授权只在本进程第一次真正要发时请求一次；之后直接投递——未授权时 add 本身就是
        // 空操作，没必要每条通知都再走一遍授权请求。
        guard !hasRequestedAuthorization else {
            center.add(request)
            return
        }
        hasRequestedAuthorization = true
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            center.add(request)
        }
    }
}

/// 前台横幅展示（菜单栏 App 大部分时间处于"前台"，缺省 delegate 会静默吞掉通知）。
private final class ForegroundPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ForegroundPresenter()

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
