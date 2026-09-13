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
                    print("🗑 已清空评级历史：\(storeURL.path)")
                } catch {
                    throw RuntimeError("清空评级历史失败：\(error)")
                }
            } else {
                print("🗑 没有可清空的历史（\(storeURL.path)）")
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
            throw RuntimeError("评级历史保存失败：\(error)")
        }

        let rating = engine.overallRating()
        print("🏷 线缆评级（基于 \(rating.sampleCount) 次协商观测）")
        print("   \(rating.summary)")
        var observed = "   观测窗口："
        if let first = rating.firstSeen {
            observed += "首次 \(Fmt.timeString(first, format: "yyyy-MM-dd HH:mm"))"
        }
        if let last = rating.lastSeen {
            observed += observed.hasSuffix("：") ? "最近 \(Fmt.timeString(last, format: "yyyy-MM-dd HH:mm"))" : " · 最近 \(Fmt.timeString(last, format: "yyyy-MM-dd HH:mm"))"
        }
        if !observed.hasSuffix("：") { print(observed) }
        print("💾 已保存到 \(storeURL.path)")
    }
}
