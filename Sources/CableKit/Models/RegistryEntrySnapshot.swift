import Foundation

/// 一条 IORegistry 条目的完整属性快照（按 IOKit 类名枚举得到）。
public struct RegistryEntrySnapshot: Codable, Hashable, Sendable, Identifiable {
    /// IORegistry entry id，全系统唯一
    public let registryID: UInt64
    /// registry 条目名（IORegistryEntryGetName），可能为空
    public let name: String?
    /// 实际对象类名（IOObjectGetClass）
    public let className: String
    /// 全量原始属性
    public let properties: [String: IORegistryValue]

    public init(registryID: UInt64, name: String?, className: String,
                properties: [String: IORegistryValue]) {
        self.registryID = registryID
        self.name = name
        self.className = className
        self.properties = properties
    }

    public var id: UInt64 { registryID }

    /// 展示标题：优先条目名，缺失时退回类名。
    public var displayTitle: String {
        let title = name?.isEmpty == false ? name! : className
        return title
    }
}
