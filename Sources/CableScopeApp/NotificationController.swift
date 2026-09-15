import CableKit
import Foundation
@preconcurrency import UserNotifications

/// 插拔通知：线缆接入/断开时发一条系统通知（"已连接 USB-C · ⚡98W · 5A 被动线缆"）。
///
/// - 快照流本身做了内容签名去重，因此 ingest 只在会话集合真实变化时到达；
/// - 首个快照作为基线，不产生通知（避免每次启动弹一堆"已连接"）；
/// - 通知授权懒请求（首次真正要发时才问）；SPM 直接运行（无 bundle）时静默禁用。
@MainActor
final class NotificationController {
    private var knownSessionIDs: Set<String>?

    /// 是否可用：仅在打包含 bundle ID 时启用（SwiftPM 裸可执行没有，`UNUserNotificationCenter.current()`
    /// 会因 `bundleProxyForCurrentProcess` 为 nil 直接抛未捕获异常崩掉整个进程）。
    private nonisolated static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    nonisolated static func activate() {
        guard isAvailable else { return } // SwiftPM 裸可执行（`swift run`/`make run-app`）静默跳过
        // 前台（菜单栏形态常驻前台上下文）也要弹横幅，而不是静默入中心。
        UNUserNotificationCenter.current().delegate = ForegroundPresenter.shared
    }

    func process(snapshot: CableSnapshot, port: @escaping (CableSession) -> USBCPortSnapshot?) {
        guard Self.isAvailable else { return }
        let currentIDs = Set(snapshot.sessions.map(\.id))

        guard let known = knownSessionIDs else {
            knownSessionIDs = currentIDs // 基线
            return
        }
        knownSessionIDs = currentIDs

        let added = snapshot.sessions.filter { !known.contains($0.id) }
        let removed = known.subtracting(currentIDs)

        for session in added {
            deliver(title: "已连接 \(session.shortPortLabel)",
                    body: connectBody(session: session, port: port(session)))
        }
        if !removed.isEmpty {
            let label = removed.count == 1 ? "1 根线缆" : "\(removed.count) 根线缆"
            deliver(title: "线缆已断开", body: "拔出了 \(label)")
        }
    }

    private func connectBody(session: CableSession, port: USBCPortSnapshot?) -> String {
        var parts: [String] = []
        if let headline = DiagnosticsEngine.portHeadline(port: port, power: nil) {
            parts.append(headline)
        } else if let speed = session.topUSBSpeed {
            parts.append("\(speed.generation) \(speed.label)")
        } else if session.deviceCount == 0 {
            parts.append("端口无设备")
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

/// 前台横幅展示（菜单栏 App 大部分时间处于"前台"，缺省 delegate 会静默吞掉通知）。
private final class ForegroundPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ForegroundPresenter()

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
