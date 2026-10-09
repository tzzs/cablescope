import CableKit
import Foundation
@preconcurrency import UserNotifications

/// 线缆变化通知：插拔 + "线缆插着不动但状态变了"（开始/停止充电、协商速率提升、
/// 评级提升）。事件本身由 `CableKit.NotificationDiff`（纯函数，可单测）推断，这里只管
/// "要不要发"（按 `AppPreferences` 的总开关/细分开关）和"怎么发"（`UNUserNotificationCenter`）。
///
/// - 冷启动（首个快照）不产生任何事件，规则在 `NotificationDiff` 里，这里不用特殊处理；
/// - 同一端口的插拔、充电开始/停止各自按 5 秒限流（`NotificationThrottle`），线头接触
///   不良时不刷屏；插拔/充电事件同时触发小组件即时刷新（`WidgetRefresher`）；
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
        switch event {
        case .sessionConnected(let sessionID):
            guard AppPreferences.isNotificationEnabled(.plugUnplug),
                  throttle.allow("plug.\(sessionID)"),
                  let session = snapshot.sessions.first(where: { $0.id == sessionID }) else { return }
            let template = AppLocalization.string("已连接 %@", locale: locale)
            deliver(title: String(format: template, session.shortPortLabel(locale: locale)),
                    body: connectBody(session: session, port: port(session), locale: locale),
                    thread: sessionID)

        case .sessionDisconnected(let sessionID):
            guard AppPreferences.isNotificationEnabled(.plugUnplug),
                  throttle.allow("plug.\(sessionID)") else { return }
            let body: String
            if let session = previousSessions[sessionID] {
                let template = AppLocalization.string("%@ 已断开", locale: locale)
                body = String(format: template, session.shortPortLabel(locale: locale))
            } else {
                body = ""
            }
            deliver(title: AppLocalization.string("线缆已断开", locale: locale), body: body, thread: sessionID)

        case .chargingStarted:
            guard AppPreferences.isNotificationEnabled(.chargingStarted),
                  throttle.allow("charging") else { return }
            deliver(title: AppLocalization.string("开始充电", locale: locale),
                    body: chargingBody(snapshot.power, locale: locale),
                    thread: "charging")

        case .chargingStopped:
            guard AppPreferences.isNotificationEnabled(.chargingStopped),
                  throttle.allow("charging") else { return }
            deliver(title: AppLocalization.string("已停止充电", locale: locale), body: "", thread: "charging")

        case .usbSpeedUpgraded(let sessionID, let speed):
            guard AppPreferences.isNotificationEnabled(.speedUpgraded),
                  let session = snapshot.sessions.first(where: { $0.id == sessionID }) else { return }
            let template = AppLocalization.string("%@ 协商速率提升", locale: locale)
            deliver(title: String(format: template, session.shortPortLabel(locale: locale)),
                    body: "\(speed.generation) \(speed.label)",
                    thread: sessionID)

        case .ratingUpgraded(let sessionID, let dimension):
            guard AppPreferences.isNotificationEnabled(.ratingUpgraded),
                  let session = snapshot.sessions.first(where: { $0.id == sessionID }) else { return }
            let template = AppLocalization.string("%@ 线缆评级提升", locale: locale)
            deliver(title: String(format: template, session.shortPortLabel(locale: locale)),
                    body: dimension.localizedDescription(locale: locale),
                    thread: sessionID)
        }
    }

    /// 开始充电时附上 PD 合同功率（比瞬时功率稳定：刚接通的头几秒瞬时读数还在爬升）。
    private func chargingBody(_ power: PowerSnapshot?, locale: Locale) -> String {
        guard let contract = power?.pdContract else { return "" }
        let template = AppLocalization.string("PD 合同 %lldW", locale: locale)
        return String(format: template, Int(contract.watts.rounded()))
    }

    private func connectBody(session: CableSession, port: USBCPortSnapshot?, locale: Locale) -> String {
        var parts: [String] = []
        if let headline = DiagnosticsEngine.portHeadline(port: port, power: nil, locale: locale) {
            parts.append(headline)
        } else if let speed = session.topUSBSpeed {
            parts.append("\(speed.generation) \(speed.label)")
        } else if session.deviceCount == 0 {
            parts.append(AppLocalization.string("端口无设备", locale: locale))
        }
        return parts.joined(separator: " · ")
    }

    /// - Parameter thread: 通知中心按它分组——同一个端口的插拔/提升归在一起，而不是平铺一长串。
    private func deliver(title: String, body: String, thread: String) {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.threadIdentifier = thread
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

private extension RatingUpgradeDimension {
    func localizedDescription(locale: Locale) -> String {
        switch self {
        case .fiveAmpConfirmed: return AppLocalization.string("首次确认支持 5A", locale: locale)
        case .displayLink: return AppLocalization.string("显示器链路规格提升", locale: locale)
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
