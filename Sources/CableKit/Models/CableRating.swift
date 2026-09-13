import Foundation

// MARK: - 线缆评级（CableScope 差异化核心）
//
// 线缆的 e-marker 芯片无法直接读取；评级引擎基于"历史协商峰值"推断线缆规格下限。

/// 线缆能力卡
public struct CableRating: Codable, Hashable, Sendable {
    /// 历史观测到的最高 USB 协商速率（bps）
    public let maxUSBBitsPerSecond: Int?
    /// 历史观测到的最高充电功率 W
    public let maxChargingWatts: Double?
    /// 是否出现过 5A 合同（⇒ e-marker 5A 线）
    public let is5ACable: Bool
    /// 历史观测到的最高 DP 链路速率标签
    public let maxDisplayLinkRate: String?
    /// 历史观测到的最高刷新率
    public let maxRefreshRateHz: Double?
    /// 参与评级的快照数量
    public let sampleCount: Int
    /// 首次/最近观测时间
    public let firstSeen: Date?
    public let lastSeen: Date?

    public init(maxUSBBitsPerSecond: Int?,
                maxChargingWatts: Double?,
                is5ACable: Bool,
                maxDisplayLinkRate: String?,
                maxRefreshRateHz: Double?,
                sampleCount: Int,
                firstSeen: Date?,
                lastSeen: Date?) {
        self.maxUSBBitsPerSecond = maxUSBBitsPerSecond
        self.maxChargingWatts = maxChargingWatts
        self.is5ACable = is5ACable
        self.maxDisplayLinkRate = maxDisplayLinkRate
        self.maxRefreshRateHz = maxRefreshRateHz
        self.sampleCount = sampleCount
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
    }

    /// 单行摘要，如 "至少 USB4 / 40Gbps ⚡ 100W(5A) 🖥 4K@60"
    public var summary: String {
        var parts: [String] = []
        if let bps = maxUSBBitsPerSecond {
            parts.append(USBSpeed(bitsPerSecond: bps).generation + " " + USBSpeed(bitsPerSecond: bps).label)
        } else {
            parts.append("未观测到高速 USB 协商")
        }
        if is5ACable, let w = maxChargingWatts, w > 0 {
            parts.append(String(format: "⚡ %.0fW（5A e-marker 线）", w))
        } else if let w = maxChargingWatts, w > 0 {
            parts.append(String(format: "⚡ %.0fW", w))
        }
        if let link = maxDisplayLinkRate {
            var video = "🖥 \(link)"
            if let hz = maxRefreshRateHz {
                video += String(format: " @ %.0fHz", hz)
            }
            parts.append(video)
        }
        return parts.joined(separator: " · ")
    }
}

/// 评级引擎协议：按线缆会话（物理端口）聚合历史快照峰值
public protocol CableRatingEngineProtocol: Sendable {
    /// 记录一次快照（内部按线缆会话分桶聚合）
    mutating func record(_ snapshot: CableSnapshot)
    /// 当前整体评级（全端口 + 整机桶聚合）
    func overallRating() -> CableRating
    /// 指定线缆会话的评级（会话 id 见 `CableSession.id`，如 "usb-0x014" / "tb-2"）
    func rating(forSessionID sessionID: String) -> CableRating?
    /// 持久化到磁盘（JSON）
    func save(to url: URL) throws
    /// 从磁盘恢复历史
    static func load(from url: URL) throws -> Self
}
