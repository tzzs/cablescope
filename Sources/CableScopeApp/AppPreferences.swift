import CableKit
import Foundation
import SwiftUI

/// App 侧轻量偏好设置（UserDefaults 持久化）：Dock 图标、语言、主题、通知开关。
/// 单独拆出常量键避免散落在各 View/Controller 文件里硬编码字符串。
///
/// 语言/主题的 key 与 raw 值取自 `CableKit.SharedAppPreferences`——Widget 进程要按
/// App 的 bundle ID 读这两项偏好，两边必须用同一份字符串，故以 CableKit 那份为准。
enum AppPreferences {
    // MARK: 在 Dock 显示图标

    static let showDockIconKey = "showDockIcon"

    /// 默认 false：保持菜单栏工具一贯的"只占状态栏"形态，用户可在菜单面板/设置页手动打开。
    static var showDockIcon: Bool {
        UserDefaults.standard.bool(forKey: showDockIconKey)
    }

    // MARK: 启动时打开主窗口

    static let openMainWindowOnLaunchKey = "openMainWindowOnLaunch"
    static let hasLaunchedBeforeKey = "hasLaunchedBefore"

    /// 启动时是否拉起主窗口。首次启动无条件打开（新用户得先看到这个 App 在干什么，
    /// 菜单栏小图标很容易被忽略）；之后按用户偏好。偏好默认开，保持此前"每次启动都
    /// 打开主窗口"的行为不变——开了"登录时启动"、不想每次开机弹窗的用户自己关掉即可。
    static func shouldOpenMainWindowOnLaunch(isFirstLaunch: Bool, preference: Bool) -> Bool {
        isFirstLaunch || preference
    }

    /// 读出本次启动的决定，并把"已启动过"记下来。每次进程启动只应调用一次
    /// （`CableScopeApp.init`），第二次调用时首次启动标记已被消费。
    static func consumeLaunchDecision(_ defaults: UserDefaults = .standard) -> Bool {
        let isFirstLaunch = !defaults.bool(forKey: hasLaunchedBeforeKey)
        defaults.set(true, forKey: hasLaunchedBeforeKey)
        return shouldOpenMainWindowOnLaunch(isFirstLaunch: isFirstLaunch,
                                            preference: defaults.bool(forKey: openMainWindowOnLaunchKey))
    }

    // MARK: 语言

    enum Language: String, CaseIterable, Identifiable {
        case system, zhHans, english
        var id: Self { self }

        /// "跟随系统"用 `autoupdatingCurrent` 而非 `.current`：只有前者能在该档位下
        /// 不重启就响应系统语言变化。其余档位走 `SharedAppPreferences` 的映射，
        /// 与 Widget 读到的结果保证一致。
        var resolvedLocale: Locale {
            SharedAppPreferences.locale(forLanguageRawValue: rawValue) ?? .autoupdatingCurrent
        }
    }
    static let languageKey = SharedAppPreferences.languageKey

    /// 拿不到 SwiftUI `\.locale` environment 的地方（`NotificationController`/`UpdateChecker`
    /// 等 AppKit/系统层代码）用这个取当前生效语言。
    static func effectiveLocale() -> Locale {
        let raw = UserDefaults.standard.string(forKey: languageKey) ?? Language.system.rawValue
        return (Language(rawValue: raw) ?? .system).resolvedLocale
    }

    // MARK: 主题

    enum Theme: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: Self { self }

        /// 映射同样走 `SharedAppPreferences`，与 Widget 读到的结果保证一致。
        var resolvedColorScheme: ColorScheme? {
            switch SharedAppPreferences.appearance(forThemeRawValue: rawValue) {
            case .light: return .light
            case .dark: return .dark
            case nil: return nil
            }
        }
    }
    static let themeKey = SharedAppPreferences.themeKey

    // MARK: 通知

    enum NotificationKind: String, CaseIterable, Identifiable {
        case plugUnplug, chargingStarted, chargingStopped, speedUpgraded, ratingUpgraded
        var id: Self { self }
        var storageKey: String { "notify.\(rawValue)" }

        /// 插拔沿用现状"无条件开"；其余四类是新行为，默认关闭（opt-in），
        /// 避免升级后突然对老用户狂发之前完全没有的通知类型。
        var defaultEnabled: Bool { self == .plugUnplug }
    }
    static let notificationsEnabledKey = "notificationsEnabled"

    /// 总开关关闭时任何细分类型都不发；总开关打开时按各自的细分开关判断。
    static func isNotificationEnabled(_ kind: NotificationKind) -> Bool {
        guard UserDefaults.standard.bool(forKey: notificationsEnabledKey) else { return false }
        return UserDefaults.standard.bool(forKey: kind.storageKey)
    }

    // MARK: 启动期默认值注册

    /// 新增的 Bool 型 key 必须注册默认值，不能依赖 `UserDefaults.bool(forKey:)` 对未设置
    /// key 隐式返回 `false` 的行为——插拔通知历史上是"无条件开"，若不注册默认值，
    /// 老用户升级后会静默变成关闭插拔通知，这是回归。必须在 `CableScopeApp.init()`
    /// 里任何读取这些偏好的代码之前调用 `UserDefaults.standard.register(defaults:)`。
    static var registrationDefaults: [String: Any] {
        var defaults: [String: Any] = [
            notificationsEnabledKey: true,
            openMainWindowOnLaunchKey: true,
            // 自动检查更新默认关：PRIVACY.md 承诺"不点就不联网"，打开它是用户的显式选择。
            UpdateChecker.autoCheckKey: false,
            languageKey: Language.system.rawValue,
            themeKey: Theme.system.rawValue,
        ]
        for kind in NotificationKind.allCases {
            defaults[kind.storageKey] = kind.defaultEnabled
        }
        return defaults
    }
}
