import Foundation

/// IORegistry 条目的轻量索引记录，不包含完整属性。
public struct RegistryEntryIndexItem: Codable, Hashable, Sendable, Identifiable {
    public let registryID: UInt64
    public let name: String?
    public let className: String
    /// 可用于重新打开条目的 registry plane path；同一条目可能有多个 plane 来源。
    public let planePaths: [String: String]

    public init(registryID: UInt64, name: String?, className: String, planePaths: [String: String]) {
        self.registryID = registryID
        self.name = name
        self.className = className
        self.planePaths = planePaths
    }

    public var id: UInt64 { registryID }
    public var displayTitle: String { name?.isEmpty == false ? name! : className }

    /// 以调用方 locale 列出该条目成功索引到的 plane 来源。
    public func sourceSummary(locale: Locale) -> String {
        let sources = planePaths.keys.sorted().joined(separator: ", ")
        return KitLocalization.format("IORegistry plane 来源：%@", locale: locale, sources)
    }
}

/// 跨 plane 的轻量索引结果及完整性信息。
public struct RegistryIndexResult: Sendable {
    public let entries: [RegistryEntryIndexItem]
    public let indexedPlanes: [String]
    public let failedPlanes: [String]
    public let truncated: Bool
    public let failedCount: Int

    public init(entries: [RegistryEntryIndexItem], indexedPlanes: [String], failedPlanes: [String],
                truncated: Bool, failedCount: Int) {
        self.entries = entries
        self.indexedPlanes = indexedPlanes
        self.failedPlanes = failedPlanes
        self.truncated = truncated
        self.failedCount = failedCount
    }
}

/// 选中条目的按需详情结果。
public struct RegistryDetailResult: Sendable {
    public let entry: RegistryEntrySnapshot?
    public let failed: Bool

    public init(entry: RegistryEntrySnapshot?, failed: Bool) {
        self.entry = entry
        self.failed = failed
    }
}
