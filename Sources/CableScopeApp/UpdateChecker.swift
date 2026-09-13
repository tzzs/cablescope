import AppKit
import Foundation

/// 应用内更新检查：查询 GitHub Releases 最新版本并与当前构建版本比较。
/// 仓库地址为占位符 —— 开源后把 OWNER 替换为实际 GitHub 用户/组织名。
enum UpdateChecker {
    /// GitHub 仓库占位地址（开源后替换 OWNER）。
    static let repositoryURL = "https://github.com/OWNER/cablescope"

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

    // MARK: - 更新提示对话框

    /// 弹出更新提示："发现新版本 <latest> / 当前 <current 或 开发版>"。
    /// 用户选择"前往下载页"则打开 GitHub Releases 页面。
    @MainActor
    static func presentUpdateDialog(current: String?, latest: String) {
        let alert = NSAlert()
        alert.messageText = "发现新版本 \(latest)"
        alert.informativeText = "当前版本：\(current ?? "开发版")"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "前往下载页")
        alert.addButton(withTitle: "以后再说")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let releasesPage = URL(string: repositoryURL)?
            .appendingPathComponent("releases")
            .appendingPathComponent("latest")
        if let releasesPage {
            NSWorkspace.shared.open(releasesPage)
        }
    }
}
