import Foundation

// MARK: - 评级历史统一存储
//
// 历史上 App 与 CLI 各写各的文件（app-ratings.json / ratings.json），互不相通。
// RatingStore 收敛为单一 canonical 文件（ratings.json），两端口共用：
// - 首次访问时把旧 app-ratings.json 幂等合并进 canonical（峰值取大、窗口取并集），合并成功后删除旧文件；
// - 删除旧文件是为了 `rating --reset` 后旧数据不会复活；
// - 迁移失败（写不进 canonical）时保留旧文件，下次再试，不丢数据。

public enum RatingStore {
    /// 统一存储路径：~/Library/Application Support/CableScope/ratings.json
    public static var canonicalURL: URL {
        baseDirectory.appendingPathComponent("CableScope/ratings.json")
    }

    /// App 旧存储（迁移源）：~/Library/Application Support/CableScope/app-ratings.json
    public static var legacyAppURL: URL {
        baseDirectory.appendingPathComponent("CableScope/app-ratings.json")
    }

    private static var baseDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    /// 加载统一评级历史（含旧 app-ratings.json 的一次性幂等迁移）。
    /// 文件缺失/损坏按全新统计处理，与既有行为一致。
    public static func loadEngine() -> CableRatingEngine {
        loadEngine(canonicalURL: canonicalURL, legacyURL: legacyAppURL)
    }

    /// 可注入路径版本（单测用）：迁移逻辑与生产路径完全一致。
    static func loadEngine(canonicalURL: URL, legacyURL: URL) -> CableRatingEngine {
        let fileManager = FileManager.default
        var engine = (try? CableRatingEngine.load(from: canonicalURL)) ?? CableRatingEngine()

        guard fileManager.fileExists(atPath: legacyURL.path) else { return engine }
        guard let legacy = try? CableRatingEngine.load(from: legacyURL) else {
            // 旧文件损坏：直接清掉，避免永远卡在迁移分支。
            try? fileManager.removeItem(at: legacyURL)
            return engine
        }
        engine.merge(legacy)
        do {
            try engine.save(to: canonicalURL)
            try? fileManager.removeItem(at: legacyURL)
        } catch {
            // canonical 写不进去：保留旧文件，下次重试。
        }
        return engine
    }
}
