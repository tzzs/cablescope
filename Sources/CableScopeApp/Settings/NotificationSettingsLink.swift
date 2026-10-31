import AppKit
import Foundation

/// 从 App 内跳到「系统设置 → 通知 → CableScope」。
///
/// **为什么要 App 专属深链**：通用的通知面板
/// （`com.apple.preference.notifications`）只把用户丢到通知列表，还得自己找到
/// CableScope 那一行、再找对「允许通知」这个总开关。通知页里还有提醒样式、声音、
/// 预览、分组等一堆控件，用户很容易改错地方，以为开了其实没开。
///
/// `com.apple.Notifications-Settings.extension?id=<bundle-id>` 会直接落在该 App 的
/// 通知页（macOS 13+，本 App 最低要求 14），页面上第一个开关就是「允许通知」。
/// 已在本机实测（macOS 26）：落地页标题为 CableScope，开关即「允许通知」。
///
/// 深链不是公开 API，行为可能随系统版本变化，所以打开失败时退回通用通知面板——
/// 落到一个略宽泛的位置，也好过按钮点了没反应。
enum NotificationSettingsLink {
    /// App 专属通知页的深链（纯函数，便于单测）。
    static func appSettingsURL(bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "") -> URL? {
        guard !bundleIdentifier.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "x-apple.systempreferences"
        components.path = "com.apple.Notifications-Settings.extension"
        components.queryItems = [URLQueryItem(name: "id", value: bundleIdentifier)]
        return components.url
    }

    /// 通用通知面板（App 专属深链打不开时的兜底）。
    static let notificationsPaneURL = URL(string: "x-apple.systempreferences:com.apple.preference.notifications")

    /// 打开 App 专属通知页；失败则退回通用面板。两者都打不开时什么也不做。
    static func open() {
        if let url = appSettingsURL(), NSWorkspace.shared.open(url) { return }
        if let fallback = notificationsPaneURL {
            NSWorkspace.shared.open(fallback)
        }
    }
}
