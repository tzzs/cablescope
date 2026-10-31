import XCTest
@testable import CableScopeApp

/// 通知设置深链的 URL 构造。
///
/// 回归背景：原来按钮跳的是通用通知面板，用户还得自己在列表里找到 CableScope、
/// 再找对「允许通知」总开关——通知页里还有提醒样式/声音/预览/分组等控件，很容易
/// 改错地方却以为已经开了。改成 App 专属深链后，落地页就是该 App 的通知设置。
final class NotificationSettingsLinkTests: XCTestCase {
    func testAppSettingsURLPointsAtAppSpecificNotificationsPage() throws {
        let url = try XCTUnwrap(NotificationSettingsLink.appSettingsURL(bundleIdentifier: "com.cablescope.app"))
        XCTAssertEqual(url.scheme, "x-apple.systempreferences")
        // 断言完整字符串而不是 `url.path`：`x-apple.systempreferences` 是非层级 scheme，
        // 各系统版本的 Foundation 对 opaque URL 的 path 解析不一致（macOS 15 上 `path`
        // 返回空串，较新版本才返回扩展名）。深链是否可用只取决于完整字符串。
        XCTAssertEqual(
            url.absoluteString,
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.cablescope.app"
        )
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query, [URLQueryItem(name: "id", value: "com.cablescope.app")])
    }

    /// 没有 bundle ID（裸 `swift run` 可执行）时构造不出深链，调用方应退回通用面板。
    func testAppSettingsURLIsNilWithoutBundleIdentifier() {
        XCTAssertNil(NotificationSettingsLink.appSettingsURL(bundleIdentifier: ""))
    }

    /// 兜底的通用通知面板必须始终可用——App 专属深链不是公开 API，可能随系统版本失效。
    func testFallbackNotificationsPaneURLExists() {
        XCTAssertNotNil(NotificationSettingsLink.notificationsPaneURL)
    }
}
