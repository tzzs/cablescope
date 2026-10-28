import CableKit
import Foundation

// MARK: - rating 子命令：记录本次快照并打印线缆评级（基于历史协商峰值推断）
//
// 历史持久化于 ~/Library/Application Support/CableScope/ratings.json

extension CableScopeCLI {
    /// - Parameter storeURL: 评级历史文件路径；默认生产路径（`~/Library/Application Support/CableScope/ratings.json`）。
    ///   单测注入临时目录路径，**绝不碰用户真实的评级历史**。
    static func runRating(reset: Bool, storeURL: URL = RatingStore.canonicalURL) async throws {
        if reset {
            let message = try resetRatingHistory(at: storeURL)
            print("🗑 " + message)
            return
        }

        // RatingStore 内含旧 app-ratings.json 的幂等迁移（App/CLI 统一到 ratings.json）。
        var engine = RatingStore.loadEngine()

        let snapshot = await acquireSnapshot()
        engine.record(snapshot)
        do {
            try engine.save(to: storeURL)
        } catch {
            throw RuntimeError(L("评级历史保存失败：%@", String(describing: error)))
        }

        for line in ratingLines(engine.overallRating(), storeURL: storeURL) {
            print(line)
        }
    }

    /// 清空评级历史文件，返回提示文案。
    ///
    /// 文件不存在时不是错误——只是没有可清空的历史，返回另一句提示。
    static func resetRatingHistory(at url: URL) throws -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            return L("没有可清空的历史（%@）", url.path)
        }
        do {
            try fm.removeItem(at: url)
            return L("已清空评级历史：%@", url.path)
        } catch {
            throw RuntimeError(L("清空评级历史失败：%@", String(describing: error)))
        }
    }

    /// 评级报告的展示行（纯函数：不碰 IOKit、不碰磁盘，便于单测）。
    static func ratingLines(_ rating: CableRating, storeURL: URL) -> [String] {
        var lines: [String] = []
        lines.append("🏷 " + L("线缆评级（基于 %lld 次协商观测）", rating.sampleCount))
        lines.append("   \(rating.summary(locale: CLILanguage.locale))")
        // 观测窗口：各段先收集再整体拼接，不再靠"末尾是不是全角冒号"判断有没有内容。
        var window: [String] = []
        if let first = rating.firstSeen {
            window.append(L("首次 %@", Fmt.timeString(first, format: "yyyy-MM-dd HH:mm")))
        }
        if let last = rating.lastSeen {
            window.append(L("最近 %@", Fmt.timeString(last, format: "yyyy-MM-dd HH:mm")))
        }
        if !window.isEmpty { lines.append("   " + L("观测窗口：%@", window.joined(separator: " · "))) }
        lines.append("💾 " + L("已保存到 %@", storeURL.path))
        return lines
    }
}
