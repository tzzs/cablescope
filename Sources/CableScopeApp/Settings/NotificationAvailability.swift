import Foundation
import Security

/// 能不能安全碰 `UNUserNotificationCenter`——`NotificationController`（发通知）和
/// `SettingsView` 的通知授权检查（查/请求授权状态）两处调用点共用同一份判断，
/// 避免各写一份、其中一处漏掉某个条件。
///
/// 两个必要条件：
/// 1. 有 bundle ID——排除 SwiftPM 裸可执行（`swift run`）：`Bundle.main.bundleIdentifier`
///    为 nil 时 `UNUserNotificationCenter.current()` 会因 `bundleProxyForCurrentProcess`
///    为 nil 直接抛未捕获异常崩掉整个进程。
/// 2. 有效代码签名——排除完全未签名的 `.app`（`bundle_app.sh` 不设
///    `CODESIGN_IDENTITY` 时产出的调试包）：实测（真机崩溃日志）较新版本 macOS 下
///    `UNUserNotificationCenter.current()` 内部会对未签名进程的代码签名做校验，
///    校验失败时通过 Objective-C `NSAssertionHandler` 抛异常——这类异常 Swift 的
///    `try/catch` 接不住（不是 Swift `Error`），唯一的办法是提前用
///    `SecCodeCheckValidity` 探测签名有效性，压根不触发这次调用。
///    Developer ID 签名/公证过的正式发布包（DMG）不受影响；本地未签名调试构建下
///    通知功能会被这里禁用，而不是崩溃。
enum NotificationAvailability {
    static var isAvailable: Bool {
        guard Bundle.main.bundleIdentifier != nil else { return false }
        return hasValidCodeSignature
    }

    private static let hasValidCodeSignature: Bool = {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else { return false }
        return SecCodeCheckValidity(code, SecCSFlags(), nil) == errSecSuccess
    }()
}
