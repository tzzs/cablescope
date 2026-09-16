import CableKit
import Foundation
@preconcurrency import UserNotifications

/// 线缆变化通知：插拔 + "线缆插着不动但状态变了"（开始/停止充电、协商速率提升、
/// 评级提升）。事件本身由 `CableKit.NotificationDiff`（纯函数，可单测）推断，这里只管
/// "要不要发"（按 `AppPreferences` 的总开关/细分开关）和"怎么发"（`UNUserNotificationCenter`）。
///
/// - 冷启动（首个快照）不产生任何事件，规则在 `NotificationDiff` 里，这里不用特殊处理；
/// - 通知授权懒请求（首次真正要发时才问）；SPM 直接运行（无 bundle）时静默禁用。
@MainActor
final class NotificationController {
    private var baseline: NotificationBaseline?

    /// 是否可用：仅在打包含 bundle ID 时启用（SwiftPM 裸可执行没有，`UNUserNotificationCenter.current()`
    /// 会因 `bundleProxyForCurrentProcess` 为 nil 直接抛未捕获异常崩掉整个进程）。
    private nonisolated static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    nonisolated static func activate() {
        guard isAvailable else { return } // SwiftPM 裸可执行（`swift run`/`make run-app`）静默跳过
        // 前台（菜单栏形态常驻前台上下文）也要弹横幅，而不是静默入中心。
        UNUserNotificationCenter.current().delegate = ForegroundPresenter.shared
    }

    func process(snapshot: CableSnapshot,
                ratingEngine: CableRatingEngineProtocol,
                port: @escaping (CableSession) -> USBCPortSnapshot?) {
        guard Self.isAvailable else { return }
        let (events, newBaseline) = NotificationDiff.diff(baseline: baseline, snapshot: snapshot,
                                                           ratingEngine: ratingEngine)
        baseline = newBaseline
        guard !events.isEmpty else { return }

        let locale = AppPreferences.effectiveLocale()
        for event in events {
            deliver(for: event, snapshot: snapshot, port: port, locale: locale)
        }
    }

    private func deliver(for event: CableNotificationEvent,
                         snapshot: CableSnapshot,
                         port: @escaping (CableSession) -> USBCPortSnapshot?,
                         locale: Locale) {
        switch event {
        case .sessionConnected(let sessionID):
            guard AppPreferences.isNotificationEnabled(.plugUnplug),
                  let session = snapshot.sessions.first(where: { $0.id == sessionID }) else { return }
            let template = AppLocalization.string("已连接 %@", locale: locale)
            deliver(title: String(format: template, session.shortPortLabel),
                    body: connectBody(session: session, port: port(session), locale: locale))

        case .sessionDisconnected:
            guard AppPreferences.isNotificationEnabled(.plugUnplug) else { return }
            deliver(title: AppLocalization.string("线缆已断开", locale: locale),
                    body: AppLocalization.string("拔出了 1 根线缆", locale: locale))

        case .chargingStarted:
            guard AppPreferences.isNotificationEnabled(.chargingStarted) else { return }
            deliver(title: AppLocalization.string("开始充电", locale: locale), body: "")

        case .chargingStopped:
            guard AppPreferences.isNotificationEnabled(.chargingStopped) else { return }
            deliver(title: AppLocalization.string("已停止充电", locale: locale), body: "")

        case .usbSpeedUpgraded(let sessionID, let speed):
            guard AppPreferences.isNotificationEnabled(.speedUpgraded),
                  let session = snapshot.sessions.first(where: { $0.id == sessionID }) else { return }
            let template = AppLocalization.string("%@ 协商速率提升", locale: locale)
            deliver(title: String(format: template, session.shortPortLabel),
                    body: "\(speed.generation) \(speed.label)")

        case .ratingUpgraded(let sessionID, let dimension):
            guard AppPreferences.isNotificationEnabled(.ratingUpgraded),
                  let session = snapshot.sessions.first(where: { $0.id == sessionID }) else { return }
            let template = AppLocalization.string("%@ 线缆评级提升", locale: locale)
            deliver(title: String(format: template, session.shortPortLabel),
                    body: dimension.localizedDescription(locale: locale))
        }
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

    private func deliver(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let request = UNNotificationRequest(identifier: UUID().uuidString,
                                                content: content,
                                                trigger: nil)
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
