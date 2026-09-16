import Foundation

// MARK: - CableKit 自身的本地化文案生成
//
// CableKit 是纯函数库，不依赖 SwiftUI，没有 `\.locale` environment 可用；调用方
// （App/CLI）必须显式传入 `Locale`。文案载体是 `Sources/CableKit/Resources/Localizable.xcstrings`，
// 用现有中文原句直接当 key。

/// 安全定位 CableKit 自己的 SwiftPM 资源 bundle。
///
/// **不使用 `Bundle.module`**：那个访问器在资源 bundle 整体缺失时会内部 `fatalError`，
/// 早于任何调用方的 guard/try? 生效（`VendorDirectory.swift` 记录过真机复现的崩溃）。
/// 这里手写等价的候选路径查找，全部落空只返回 nil，交给调用方决定安全回退。
enum CableKitResourceBundle {
    static func probe(
        bundleFileName: String = "CableScope_CableKit.bundle",
        candidates: [URL?] = [
            Bundle.main.resourceURL,
            Bundle(for: BundleAnchor.self).resourceURL,
            Bundle.main.bundleURL,
        ]
    ) -> Bundle? {
        for candidate in candidates {
            guard let bundleURL = candidate?.appendingPathComponent(bundleFileName),
                  FileManager.default.fileExists(atPath: bundleURL.path),
                  let bundle = Bundle(url: bundleURL) else { continue }
            return bundle
        }
        return nil
    }

    /// 懒加载一次；探测失败缓存为 nil，不会每次调用都重新扫描候选路径。
    static let shared: Bundle? = probe()
}

/// `Bundle(for:)` 的锚点类，用法等价于 `VendorDirectory.BundleAnchor`。
private final class BundleAnchor {}

enum KitLocalization {
    /// 按指定语言取本地化字符串。
    ///
    /// **不用 `String(localized:bundle:locale:)`**：实测（见 `LocalizationProbeTests`
    /// 调试记录）那个新 API 的 `locale:` 形参在这里不会按请求的语言选取译文——无论
    /// 传 `en` 还是 `zh-Hans`，返回的都是 bundle 的 `preferredLocalizations`（即系统当前
    /// 语言），而不是显式请求的语言；这与"语言切换要独立于系统 Language & Region"的
    /// 需求直接冲突。改用经典写法：按 `Bundle.preferredLocalizations(from:forPreferences:)`
    /// 手动选出目标语言对应的 `.lproj` 子 bundle，再用该子 bundle 的
    /// `localizedString(forKey:value:table:)` 查表——这条路径不依赖系统当前语言，
    /// 实测能可靠返回指定语言的译文。
    ///
    /// bundle 定位失败、目标语言没有对应 `.lproj`（例如源语言 zh-Hans 本身就没有
    /// 单独的 lproj，key 即中文原文）、或该 key 未收录时，安全退化为返回 `key` 本身，
    /// 绝不崩溃。
    static func string(_ key: String, locale: Locale) -> String {
        guard let languageBundle = languageBundle(for: locale) else { return key }
        return languageBundle.localizedString(forKey: key, value: nil, table: "Localizable")
    }

    /// 模板 + `%@` 占位符替换：数字先格式化成字符串，再套进已翻译的模板。
    ///
    /// 有意不直接把数字插值进 key 文本（如 `"PD 合同 \(watts)W"`）——模板改用字面量
    /// `%@` 占位符后，key 就是模板本身的可见文本，翻译条目怎么写、能不能对上一目了然，
    /// 不依赖任何编译期生成的隐式 key 格式。
    static func string(template: String, locale: Locale, args: String...) -> String {
        let format = string(template, locale: locale)
        return String(format: format, arguments: args)
    }

    /// 与原先 `String(format: "%.0f"/"%.1f", _)` 等价的数字格式化，供上面的模板替换使用；
    /// 有意不随 locale 变化数字进制/分隔符——保持与改造前完全一致的数字呈现。
    static func fixedFraction(_ value: Double, digits: Int) -> String {
        String(format: "%.\(digits)f", value)
    }

    /// 按 `Locale` 选出资源 bundle 里对应语言的 `.lproj` 子 bundle；找不到（含"该语言
    /// 就是源语言、没有单独 lproj"的情况）返回 nil，交给调用方回退到 key 本身。
    private static func languageBundle(for locale: Locale) -> Bundle? {
        guard let resourceBundle = CableKitResourceBundle.shared else { return nil }
        let available = resourceBundle.localizations
        guard !available.isEmpty else { return nil }
        let preferred = Bundle.preferredLocalizations(from: available, forPreferences: [locale.identifier])
        guard let best = preferred.first,
              let lprojPath = resourceBundle.path(forResource: best, ofType: "lproj"),
              let bundle = Bundle(path: lprojPath) else { return nil }
        return bundle
    }
}
