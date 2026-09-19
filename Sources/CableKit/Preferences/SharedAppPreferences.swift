import Foundation

/// App 与 Widget 之间共享的偏好读取契约。
///
/// **要解决的问题**：Widget 是独立进程、有自己的 bundle ID，它的 `UserDefaults.standard`
/// 是 widget 自己的偏好域，看不见 App 的语言/主题设置——所以 widget 一直完全跟随系统，
/// 用户在 App 里选的语言和主题对它无效。
///
/// **做法**：按主 App 的 bundle ID 直接打开它的偏好域。外部分发渠道（Developer ID）下
/// App 与 widget 都不带沙盒 entitlements，而非沙盒进程可以读任意偏好域——因此
/// **不需要 App Group，也就不依赖 Apple Developer 后台注册**（实测确认可读，且不存在的
/// 域安全返回 nil）。
///
/// **降级**：沙盒的 MAS 构建下读不到 App 的域，所有读取返回 nil，调用方按"跟随系统"处理
/// ——与改动前的行为完全一致，降级无感。真要在 MAS 版联动需要 App Group +
/// `UserDefaults(suiteName:)`，见 `Docs/04-优化路线图.md`。
///
/// key 与 raw 值在这里是单一事实源：App 侧 `AppPreferences` 复用这份常量与映射，
/// 避免两个模块各写一份字符串导致漂移（`SharedAppPreferencesTests` 里有漂移守卫）。
public enum SharedAppPreferences {
    /// 主 App 的 bundle ID，同时也是它的偏好域名。
    public static let appBundleIdentifier = "com.cablescope.app"

    /// 语言偏好 key。
    public static let languageKey = "appLanguage"
    /// 主题偏好 key。
    public static let themeKey = "appTheme"

    /// 语言偏好的 raw 值（`AppPreferences.Language` 的 rawValue 与之一一对应）。
    public enum Language: String, CaseIterable, Sendable {
        case system, zhHans, english
    }

    /// 主题偏好里"明确选了深浅色"的两档。CableKit 不依赖 SwiftUI，故不用 `ColorScheme`，
    /// 由调用方映射；"跟随系统"用 nil 表达，不占一个 case。
    public enum Appearance: String, CaseIterable, Sendable {
        case light, dark
    }

    /// 打开主 App 的偏好域；读不到（沙盒受限 / App 从未运行过）返回 nil。
    public static func appDefaults() -> UserDefaults? {
        UserDefaults(suiteName: appBundleIdentifier)
    }

    // MARK: - 纯映射（可单测，不碰 UserDefaults）

    /// 语言 raw 值 → `Locale`。nil / `system` / 无法识别的值一律表示"跟随系统"，返回 nil，
    /// 由调用方决定跟随方式（widget 侧＝不覆盖 `\.locale` environment）。
    public static func locale(forLanguageRawValue raw: String?) -> Locale? {
        switch Language(rawValue: raw ?? "") {
        case .zhHans: return Locale(identifier: "zh-Hans")
        case .english: return Locale(identifier: "en")
        case .system, nil: return nil
        }
    }

    /// 主题 raw 值 → `Appearance`。nil / `system` / 无法识别的值一律返回 nil（跟随系统）。
    public static func appearance(forThemeRawValue raw: String?) -> Appearance? {
        Appearance(rawValue: raw ?? "")
    }

    // MARK: - 从偏好域读取（defaults 可注入，便于单测）

    public static func locale(from defaults: UserDefaults?) -> Locale? {
        locale(forLanguageRawValue: defaults?.string(forKey: languageKey))
    }

    public static func appearance(from defaults: UserDefaults?) -> Appearance? {
        appearance(forThemeRawValue: defaults?.string(forKey: themeKey))
    }
}
