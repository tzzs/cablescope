import CableKit
import Foundation

// MARK: - rating 子命令：记录本次快照并打印线缆评级（基于历史协商峰值推断）
//
// 历史持久化于 ~/Library/Application Support/CableScope/ratings.json

extension CableScopeCLI {
    static func runRating(reset: Bool) async throws {
        let storeURL = RatingStore.canonicalURL

        if reset {
            let fm = FileManager.default
            if fm.fileExists(atPath: storeURL.path) {
                do {
                    try fm.removeItem(at: storeURL)
                    print("🗑 " + L("已清空评级历史：%@", storeURL.path))
                } catch {
                    throw RuntimeError(L("清空评级历史失败：%@", String(describing: error)))
                }
            } else {
                print("🗑 " + L("没有可清空的历史（%@）", storeURL.path))
            }
            return
        }

        // RatingStore 内含旧 app-ratings.json 的幂等迁移（App/CLI 统一到 ratings.json）。
        var engine = RatingStore.loadEngine()

        let snapshot = try await acquireSnapshot()
        engine.record(snapshot)
        do {
            try engine.save(to: storeURL)
        } catch {
            throw RuntimeError(L("评级历史保存失败：%@", String(describing: error)))
        }

        let rating = engine.overallRating()
        print("🏷 " + L("线缆评级（基于 %lld 次协商观测）", rating.sampleCount))
        print("   \(rating.summary(locale: CLILanguage.locale))")
        // 观测窗口：各段先收集再整体拼接，不再靠"末尾是不是全角冒号"判断有没有内容。
        var window: [String] = []
        if let first = rating.firstSeen {
            window.append(L("首次 %@", Fmt.timeString(first, format: "yyyy-MM-dd HH:mm")))
        }
        if let last = rating.lastSeen {
            window.append(L("最近 %@", Fmt.timeString(last, format: "yyyy-MM-dd HH:mm")))
        }
        if !window.isEmpty { print("   " + L("观测窗口：%@", window.joined(separator: " · "))) }
        print("💾 " + L("已保存到 %@", storeURL.path))
    }
}
