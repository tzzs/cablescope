import CableKit
import Foundation

// MARK: - CLI 文案语言
//
// CLI 没有自己的资源 bundle：Homebrew formula 只把可执行文件和 `CableScope_CableKit.bundle`
// 一起装进 libexec（见 AGENTS.md「Homebrew distribution」），新增一个 CLI 资源包就得同步
// 改 formula 的安装布局，且漏装时会静默退回中文。所以 CLI 文案与 CableKit 共用
// `Sources/CableKit/Resources/en.lproj/Localizable.strings`，key 仍是中文原句。

enum CLILanguage {
    /// 进程级生效语言，启动时解析一次。测试里可直接赋值钉死语言。
    static var locale: Locale = resolve(environment: ProcessInfo.processInfo.environment,
                                        preferredLanguages: Locale.preferredLanguages)

    /// 解析顺序：`CABLESCOPE_LANG` → `LC_ALL` → `LC_MESSAGES` → 系统首选语言。
    ///
    /// **刻意不读 `LANG`**：VS Code、iTerm 等终端会在用户没设置时自动填 `en_US.UTF-8`，
    /// 读它会让中文系统用户的 CLI 被静默切成英文；`LC_ALL`/`LC_MESSAGES` 则基本只有用户
    /// 主动设置才会出现。`C`/`POSIX` 视为未设置。
    static func resolve(environment: [String: String], preferredLanguages: [String]) -> Locale {
        for name in ["CABLESCOPE_LANG", "LC_ALL", "LC_MESSAGES"] {
            if let identifier = normalizedIdentifier(environment[name]) {
                return Locale(identifier: identifier)
            }
        }
        return Locale(identifier: preferredLanguages.first ?? "en")
    }

    /// "en_US.UTF-8" / "zh_CN.UTF-8@cjk" → "en_US" / "zh_CN"；空值与 C/POSIX 返回 nil。
    static func normalizedIdentifier(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let cut = value.firstIndex(where: { $0 == "." || $0 == "@" }) {
            value = String(value[..<cut])
        }
        guard !value.isEmpty, value != "C", value != "POSIX" else { return nil }
        return value
    }

    static var isChinese: Bool {
        locale.language.languageCode == .chinese
    }
}

/// 查 CableKit 译文表。
func L(_ key: String) -> String {
    KitLocalization.string(key, locale: CLILanguage.locale)
}

/// 查表并按同一 locale 填 `%@`/`%lld` 参数。**key 里不要写 `\(...)` 插值**——那会在查表
/// 之前就把值拼进 key，整句永远查不到译文；一律用格式符占位。
func L(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: L(key), locale: CLILanguage.locale, arguments: arguments)
}

// MARK: - 命令名

enum Invocation {
    /// 帮助与提示里展示的命令名：Homebrew 装的是 `cablescope`，开发期 `swift run` 跑的是
    /// SwiftPM target 名 `CableScopeCLI`——此前帮助里一律写死 `swift run CableScopeCLI`，
    /// brew 用户照抄会得到 "command not found"。
    static func name(argv0: String?) -> String {
        let executable = argv0.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "cablescope"
        return executable == "CableScopeCLI" ? "swift run CableScopeCLI" : executable
    }

    static let current = name(argv0: CommandLine.arguments.first)
}
