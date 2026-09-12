import CableKit
import Foundation

// MARK: - rating 子命令：记录本次快照并打印线缆评级（基于历史协商峰值推断）
//
// 历史持久化于 ~/Library/Application Support/CableScope/ratings.json

extension CableScopeCLI {
    static func runRating(reset: Bool) async throws {
        let storeURL = ratingsStoreURL

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

        // 加载历史；文件缺失 → 全新统计；文件损坏 → 提示后重新开始
        var engine: CableRatingEngine
        do {
            engine = try CableRatingEngine.load(from: storeURL)
        } catch {
            if FileManager.default.fileExists(atPath: storeURL.path) {
                FileHandle.standardError.write(Data("⚠️ 评级历史文件读取失败（\(error)），已重新开始统计。\n".utf8))
            }
            engine = CableRatingEngine()
        }

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

    private static var ratingsStoreURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("CableScope/ratings.json")
    }
}
