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
/// 文案载体是 `Resources/en.lproj/Localizable.strings`（经典 .strings 表，非 .xcstrings
/// ——部分 SwiftPM 工具链不会把 .xcstrings 编译成 .strings，见该文件顶部注释）。
///
/// 资源落地位置随构建路径不同：Xcode 打包成真正的 .app 时，资源直接进
/// `Bundle.main.resourceURL`（同一个原生 target，无嵌套）；纯 SwiftPM
/// `swift run`/`swift build`（无 bundle ID 的裸可执行）时，SwiftPM 会像 CableKit 一样
/// 把资源放进一个嵌套的 `CableScope_CableScopeApp.bundle`。两条路径都要探测到。
enum AppLocalization {
    static func string(_ key: String, locale: Locale) -> String {
        guard let languageBundle = languageBundle(for: locale) else { return key }
        return languageBundle.localizedString(forKey: key, value: nil, table: "Localizable")
    }

    /// 先找嵌套的 `CableScope_CableScopeApp.bundle`，全部落空才退回 `Bundle.main`。
    ///
    /// **顺序不能反过来**（改前的写法是"`Bundle.main.localizations` 非空就直接用
    /// `Bundle.main`"）：`swift test` 下 `Bundle.main` 是 xctest 运行器，它自带
    /// en.lproj，于是这个判断恒真、直接返回运行器 bundle，查表必然落空退回中文 key
    /// ——本地化回归测试因此永远测不到真正的资源包。反过来先探测嵌套包，三种落地
    /// 形态（SwiftPM 裸可执行 / bundle_app.sh 打的 .app / xctest）都能命中，Xcode
    /// 原生 target（资源直接进 Contents/Resources、没有嵌套包）走最后的 Bundle.main 兜底。
    private static func resourceBundle() -> Bundle {
        // 与 CableKit.CableKitResourceBundle 同款候选路径探测，各自独立一份因为这是
        // 不同模块，CableKit 的探测逻辑是 internal，不对外暴露。
        let candidates: [URL?] = [
            Bundle.main.resourceURL,
            Bundle(for: BundleAnchor.self).resourceURL,
            Bundle.main.bundleURL,
            // `swift test` 在部分工具链下不会把资源 bundle 拷进 .xctest 自己的
            // Contents/Resources，而是与 .xctest 平级放在构建产物目录里（CableKit 侧
            // 由 CI 复现过，见 9c60992）。退到 .xctest 所在目录的上一级去找。
            Bundle(for: BundleAnchor.self).bundleURL.deletingLastPathComponent(),
        ]
        for candidate in candidates {
            guard let bundleURL = candidate?.appendingPathComponent("CableScope_CableScopeApp.bundle"),
                  FileManager.default.fileExists(atPath: bundleURL.path),
                  let bundle = Bundle(url: bundleURL) else { continue }
            return bundle
        }
        return Bundle.main
    }

    /// `Bundle(for:)` 的锚点类（等价于 CableKit 侧的同名用法）。
    private final class BundleAnchor {}

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
