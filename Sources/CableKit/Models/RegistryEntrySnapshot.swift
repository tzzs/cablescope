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

    /// 每个类名对应的"次要展示属性"候选 key，按优先级排列；侧栏用它在同一类名下
    /// 区分多个条目（例如两根线各自的 IOThunderboltPort、AppleHPM 端口）。
    ///
    /// 已用真机抓包验证：
    /// - IOThunderboltPort：Description 在多个未激活端口上都是 "Port is inactive"（不唯一），
    ///   Port Number 才是可靠的端口序号。
    /// - AppleHPMInterfaceType10/11（USB-C/MagSafe 口）：name 已按端口类型区分（"Port-USB-C"
    ///   等），但同类型多口仍会撞车；Description 自带序号（如 "Port-USB-C@1"），是驱动自己拼出
    ///   的唯一标识。
    /// AppleHPMInterfaceType12/18 在测试机上没有实例，未验证，暂不填。
    public static let disambiguatingKeysByClass: [String: [String]] = [
        "IOThunderboltPort": ["Port Number"],
        "AppleHPMInterfaceType10": ["Description"],
        "AppleHPMInterfaceType11": ["Description"],
    ]

    /// 依据 disambiguatingKeysByClass 找到第一个命中且非空的候选值，格式为 "key value"。
    public var disambiguatingSubtitle: String? {
        guard let keys = Self.disambiguatingKeysByClass[className] else { return nil }
        for key in keys {
            if let value = properties[key], !value.displayText.isEmpty {
                return "\(key) \(value.displayText)"
            }
        }
        return nil
    }
}

/// 一次 IORegistry 枚举的结果：条目 + **结果是否完整**。
///
/// 单独返回完整性标志，是因为"返回 256 条"有两种截然不同的含义：
/// 该类**正好**有 256 个条目，还是**超过**了 256 被砍掉。只给数组的话调用方
/// 无法区分，而这是一个帮用户排查问题的诊断工具——把不完整的结果说成"全部"，
/// 会让排查结论建立在残缺数据上。
///
/// 不可 `Codable`：这是服务的即时返回值，不是需要落盘或跨进程传递的快照。
public struct RegistryEnumerationResult: Sendable {
    /// 已取到的条目（按 registryID 稳定排序）。
    public let entries: [RegistryEntrySnapshot]
    /// 是否因触及 `RegistryService.maxEntries` 而**丢弃了后续条目**。
    public let truncated: Bool
    /// 属性读取失败的条目数。
    ///
    /// 这些条目**不在** `entries` 里，但它们同样消耗了枚举额度——所以它与
    /// `truncated` 是两种不同的不完整：没有条目被丢弃（`truncated == false`），
    /// 但有这么多条目的属性读不出来，用户看到的仍不是全部。
    public let failedCount: Int

    public init(entries: [RegistryEntrySnapshot], truncated: Bool, failedCount: Int = 0) {
        self.entries = entries
        self.truncated = truncated
        self.failedCount = failedCount
    }

    /// 结果是否完整（既没截断，也没有读取失败的条目）。
    public var isComplete: Bool { !truncated && failedCount == 0 }
}
