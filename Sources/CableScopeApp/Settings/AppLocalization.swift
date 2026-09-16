import Foundation

/// App 自己的本地化文案生成，供拿不到 SwiftUI `\.locale` environment 的地方
/// （`NotificationController`/`UpdateChecker`，AppKit/UserNotifications 层代码）使用。
///
/// **不用 `String(localized:locale:)`**：与 `CableKit.KitLocalization` 同样的原因——
/// 实测那个新 API 的 `locale:` 形参不会按请求的语言选取译文，返回的始终是
/// `bundle.preferredLocalizations`（系统当前语言）。改用经典写法：按
/// `Bundle.preferredLocalizations(from:forPreferences:)` 手动选出目标语言对应的
/// `.lproj` 子 bundle，再用该子 bundle 的 `localizedString(forKey:value:table:)` 查表。
///
/// App 自己的 `.xcstrings` 落地位置随构建路径不同：Xcode 打包成真正的 .app 时，
/// 资源直接编译进 `Bundle.main.resourceURL`（同一个原生 target，无嵌套）；纯 SwiftPM
/// `swift run`/`swift build`（无 bundle ID 的裸可执行）时，SwiftPM 会像 CableKit 一样
/// 把资源放进一个嵌套的 `CableScope_CableScopeApp.bundle`。两条路径都要探测到。
enum AppLocalization {
    static func string(_ key: String, locale: Locale) -> String {
        guard let languageBundle = languageBundle(for: locale) else { return key }
        return languageBundle.localizedString(forKey: key, value: nil, table: "Localizable")
    }

    private static func resourceBundle() -> Bundle {
        if !Bundle.main.localizations.isEmpty { return Bundle.main }
        // 纯 SwiftPM 裸可执行：资源被放进嵌套的 CableScope_CableScopeApp.bundle
        // （与 CableKit.KitLocalization/VendorDirectory 同款候选路径探测，各自独立一份
        // 因为这是不同模块，CableKit 的探测逻辑是 internal，不对外暴露）。
        let candidates: [URL?] = [Bundle.main.resourceURL, Bundle.main.bundleURL]
        for candidate in candidates {
            guard let bundleURL = candidate?.appendingPathComponent("CableScope_CableScopeApp.bundle"),
                  FileManager.default.fileExists(atPath: bundleURL.path),
                  let bundle = Bundle(url: bundleURL) else { continue }
            return bundle
        }
        return Bundle.main
    }

    private static func languageBundle(for locale: Locale) -> Bundle? {
        let resource = resourceBundle()
        let available = resource.localizations
        guard !available.isEmpty else { return nil }
        let preferred = Bundle.preferredLocalizations(from: available, forPreferences: [locale.identifier])
        guard let best = preferred.first,
              let lprojPath = resource.path(forResource: best, ofType: "lproj"),
              let bundle = Bundle(path: lprojPath) else { return nil }
        return bundle
    }
}
