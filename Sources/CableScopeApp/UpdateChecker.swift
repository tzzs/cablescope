import AppKit
import Foundation

/// 应用内更新检查：查询 GitHub Releases 最新版本并与当前构建版本比较。
enum UpdateChecker {
    /// GitHub 仓库地址。
    static let repositoryURL = "https://github.com/tzzs/cablescope"

    // MARK: - 查询最新 Release

    /// 拉取仓库最新 Release 的 tag（tag_name）。
    /// 5 秒超时；非 2xx 状态码或 JSON 解析失败均抛错。
    static func latestReleaseTag(for repo: URL) async throws -> String {
        // https://github.com/<owner>/<repo> -> https://api.github.com/repos/<owner>/<repo>/releases/latest
        let pathParts = repo.pathComponents.filter { $0 != "/" }
        guard pathParts.count >= 2 else { throw URLError(.badURL) }
        guard let apiURL = URL(string: "https://api.github.com/repos/\(pathParts[0])/\(pathParts[1])/releases/latest") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: apiURL)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 5

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        struct Release: Decodable {
            let tagName: String
            enum CodingKeys: String, CodingKey { case tagName = "tag_name" }
        }
        return try JSONDecoder().decode(Release.self, from: data).tagName
    }

    // MARK: - 版本比较（纯函数）

    /// 判断是否有可用更新：major.minor.patch 逐段比较，latest 更大才提示。
    /// current 为 nil（无 bundle / 开发版）或任一版本号解析失败时返回 false（不打扰开发版用户）。
    static func isUpdateAvailable(current: String?, latest: String) -> Bool {
        guard let current = current,
              let currentParts = parseVersion(current),
              let latestParts = parseVersion(latest) else { return false }
        for index in 0..<3 {
            if latestParts[index] != currentParts[index] {
                return latestParts[index] > currentParts[index]
            }
        }
        return false
    }

    /// 解析 "v1.2.3" / "1.2.3" / "1.2.3-beta" -> [1, 2, 3]；段数或数字不合法返回 nil。
    private static func parseVersion(_ string: String) -> [Int]? {
        var core = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if core.hasPrefix("v") || core.hasPrefix("V") { core.removeFirst() }
        // 容忍预发布后缀（如 1.2.3-beta），只比较数字主版本段
        core = String(core.split(separator: "-", maxSplits: 1).first ?? "")
        let parts = core.split(separator: ".").map { Int($0) }
        guard parts.count == 3, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.map { $0! }
    }

    // MARK: - 安装渠道（决定"怎么升级"）

    /// 同一个 .app 可能来自三条渠道，升级方式各不相同：DMG 用户去下载页；Homebrew 用户
    /// 如果也去下载页手动覆盖，brew 的记录就和实际文件脱节，下次 `brew upgrade` 会出错。
    enum InstallChannel: Equatable {
        case direct
        case homebrewCask
        case homebrewFormula

        /// Homebrew 渠道的升级命令；直接下载渠道为 nil。
        var upgradeCommand: String? {
            switch self {
            case .direct: return nil
            case .homebrewCask: return "brew upgrade --cask cablescope"
            case .homebrewFormula: return "brew upgrade cablescope-app"
            }
        }
    }

    static let caskroomCandidates = ["/opt/homebrew/Caskroom/cablescope", "/usr/local/Caskroom/cablescope"]

    /// 纯函数（便于单测）：formula 把 .app 装在 keg 里（`…/Cellar/cablescope-app/<版本>/`），
    /// 用户再 `ln -s` 到 /Applications，所以要看**解析符号链接后**的路径；cask 则把 .app
    /// 拷进 /Applications，路径上看不出来，只能看 Caskroom 里有没有这个 token 的记录。
    static func installChannel(resolvedBundlePath: String,
                               caskroomExists: (String) -> Bool) -> InstallChannel {
        if resolvedBundlePath.contains("/Cellar/cablescope-app/") { return .homebrewFormula }
        if caskroomCandidates.contains(where: caskroomExists) { return .homebrewCask }
        return .direct
    }

    static var currentInstallChannel: InstallChannel {
        installChannel(resolvedBundlePath: Bundle.main.bundleURL.resolvingSymlinksInPath().path,
                       caskroomExists: { FileManager.default.fileExists(atPath: $0) })
    }

    // MARK: - 自动检查（opt-in，默认关闭）

    static let autoCheckKey = "autoCheckForUpdates"
    static let lastCheckKey = "lastUpdateCheck"
    static let lastNotifiedVersionKey = "lastNotifiedUpdateVersion"
    static let automaticCheckInterval: TimeInterval = 24 * 60 * 60

    /// 纯函数：距离上次检查满一天才再查。从未查过视为到期。
    static func isAutomaticCheckDue(lastCheck: Date?, now: Date) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= automaticCheckInterval
    }

    /// 纯函数：自动检查发现的同一个新版本只提醒一次——用户点了"以后再说"之后，
    /// 不该每天被同一个版本再打断一次（手动"检查更新"不受此限制）。
    static func shouldNotifyAutomatically(latest: String, lastNotified: String?) -> Bool {
        latest != lastNotified
    }

    /// 常驻循环：每 6 小时醒一次看是否到期（到期才真正发请求）。开关是每次醒来现读的，
    /// 用户中途关掉立即生效；整个循环只在开关打开时才会发任何网络请求。
    @MainActor
    static func runAutomaticChecks() async {
        while !Task.isCancelled {
            await performAutomaticCheckIfDue()
            try? await Task.sleep(nanoseconds: 6 * 60 * 60 * 1_000_000_000)
        }
    }

    @MainActor
    private static func performAutomaticCheckIfDue() async {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: autoCheckKey),
              isAutomaticCheckDue(lastCheck: defaults.object(forKey: lastCheckKey) as? Date, now: Date()),
              let repo = URL(string: repositoryURL) else { return }
        defaults.set(Date(), forKey: lastCheckKey)
        guard let latest = try? await latestReleaseTag(for: repo) else { return }
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        guard isUpdateAvailable(current: current, latest: latest),
              shouldNotifyAutomatically(latest: latest, lastNotified: defaults.string(forKey: lastNotifiedVersionKey))
        else { return }
        defaults.set(latest, forKey: lastNotifiedVersionKey)
        NSApplication.shared.activate(ignoringOtherApps: true)
        presentUpdateDialog(current: current, latest: latest, locale: AppPreferences.effectiveLocale())
    }

    // MARK: - 更新提示对话框

    /// 弹出更新提示："发现新版本 <latest> / 当前 <current 或 开发版>"。
    /// 直接下载的用户："前往下载页"打开 GitHub Releases；Homebrew 用户：给出对应的
    /// `brew upgrade` 命令并可一键拷贝（见 `InstallChannel`）。NSAlert 不在 SwiftUI view
    /// tree 上，拿不到 `\.locale` environment，文案走 `AppLocalization`（显式传当前语言）。
    @MainActor
    static func presentUpdateDialog(current: String?, latest: String, locale: Locale,
                                    channel: InstallChannel = currentInstallChannel) {
        let alert = NSAlert()
        alert.messageText = String(format: AppLocalization.string("发现新版本 %@", locale: locale), latest)
        let currentLabel = current ?? AppLocalization.string("开发版", locale: locale)
        var informative = String(format: AppLocalization.string("当前版本：%@", locale: locale), currentLabel)
        if let command = channel.upgradeCommand {
            let template = AppLocalization.string("通过 Homebrew 安装，请在终端运行：\n%@", locale: locale)
            informative += "\n\n" + String(format: template, command)
        }
        alert.informativeText = informative
        alert.alertStyle = .informational
        if channel.upgradeCommand != nil {
            alert.addButton(withTitle: AppLocalization.string("拷贝命令", locale: locale))
        } else {
            alert.addButton(withTitle: AppLocalization.string("前往下载页", locale: locale))
        }
        alert.addButton(withTitle: AppLocalization.string("以后再说", locale: locale))

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if let command = channel.upgradeCommand {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            return
        }
        let releasesPage = URL(string: repositoryURL)?
            .appendingPathComponent("releases")
            .appendingPathComponent("latest")
        if let releasesPage {
            NSWorkspace.shared.open(releasesPage)
        }
    }
}
