import Foundation

/// 评级引擎默认实现：按线缆会话（物理端口）聚合历史快照峰值（纯 Swift，无 IOKit 依赖，可单测）。
///
/// 关键规则见 Docs/03-数据获取指南.md：
/// - PD 合同 ≥ 20V/5A ⇒ e-marker 5A 线
/// - USB 协商速率取历史峰值（峰值只会抬高评级，不会因拔线清零）
///
/// 分桶规则（v2 存储格式，key 为会话 id）：
/// - 会话桶（"usb-0x014" / 端口节点 id "Port-USB-C@2" / "tb-2"）只记本会话设备的 USB 速率峰值；
/// - 电源（充电功率 / 5A 合同）按 PortGrouping.attributablePowerSessionID 归属：单线无歧义；
///   多线时恰好一个活跃端口在收电（winning 协商合同）才归属该端口——纯 PD 充电线不枚举
///   设备，靠这条才能进线缆桶；其余记入 "sys"；
/// - 显示器 v1 无法按线归属，一律记入 "sys"（只参与整机评级）。
///
/// sampleCount 语义：会话桶 = 该端口存在的快照数；overall = 各桶最大值
/// （近似"最长观测窗口"，避免多线并插时同一次快照被重复计数）。
public struct CableRatingEngine: CableRatingEngineProtocol {
    struct PortHistory: Codable {
        var maxUSBBitsPerSecond: Int?
        var maxChargingWatts: Double?
        var saw5AContract: Bool = false
        var maxDisplayLinkRate: String?
        var maxRefreshRateHz: Double?
        var sampleCount: Int = 0
        var firstSeen: Date?
        var lastSeen: Date?

        /// 取两份历史的峰值合并（用于 overall 归约与旧格式迁移的去重合并）
        mutating func merge(_ other: PortHistory) {
            if let v = other.maxUSBBitsPerSecond {
                maxUSBBitsPerSecond = max(maxUSBBitsPerSecond ?? 0, v)
            }
            if let w = other.maxChargingWatts {
                maxChargingWatts = max(maxChargingWatts ?? 0, w)
            }
            saw5AContract = saw5AContract || other.saw5AContract
            maxDisplayLinkRate = [maxDisplayLinkRate, other.maxDisplayLinkRate].compactMap { $0 }.max()
            if let hz = other.maxRefreshRateHz {
                maxRefreshRateHz = max(maxRefreshRateHz ?? 0, hz)
            }
            sampleCount = max(sampleCount, other.sampleCount)
            firstSeen = [firstSeen, other.firstSeen].compactMap { $0 }.min()
            lastSeen = [lastSeen, other.lastSeen].compactMap { $0 }.max()
        }
    }

    /// 整机桶：显示器峰值与无法按线归属的电源数据
    static let systemKey = "sys"

    /// key: 会话 id（"usb-0x014" / "tb-2"）或 "sys"
    private var histories: [String: PortHistory] = [:]

    public init() {}

    public mutating func record(_ snapshot: CableSnapshot) {
        // 会话缺失时（旧数据/测试直接构造的快照）现算一份，保证 record 不依赖采集方。
        let sessions = snapshot.sessions.isEmpty
            ? PortGrouping.buildSessions(usbDevices: snapshot.usbDevices,
                                         thunderboltDevices: snapshot.thunderboltDevices,
                                         ports: snapshot.ports)
            : snapshot.sessions

        // 电源归属：单线无歧义；多线时恰有一个在收电的端口才归属（宁缺毋滥，见 PortGrouping）。
        let attributableID = PortGrouping.attributablePowerSessionID(sessions: sessions,
                                                                     ports: snapshot.ports,
                                                                     power: snapshot.power)

        // 整机桶：显示器 + 未归属电源。只在真正记录了数据时推进计数，避免空桶。
        var sys = histories[Self.systemKey] ?? PortHistory()
        var sysTouched = false
        for display in snapshot.displays {
            if let hz = display.refreshRateHz {
                sys.maxRefreshRateHz = max(sys.maxRefreshRateHz ?? 0, hz)
            }
            if let link = display.linkRateLabel, sys.maxDisplayLinkRate == nil || link > (sys.maxDisplayLinkRate ?? "") {
                sys.maxDisplayLinkRate = link
            }
            sysTouched = true
        }
        if let power = snapshot.power, attributableID == nil {
            if power.isCharging, let watts = power.watts {
                sys.maxChargingWatts = max(sys.maxChargingWatts ?? 0, watts)
            }
            if power.pdContract?.implies5ACable == true {
                sys.saw5AContract = true
            }
            sysTouched = true
        }
        if sysTouched {
            sys.sampleCount += 1
            sys.lastSeen = snapshot.timestamp
            if sys.firstSeen == nil { sys.firstSeen = snapshot.timestamp }
            histories[Self.systemKey] = sys
        }

        // 各会话桶：USB 速率峰值 + 归属到本会话的电源数据。
        for session in sessions {
            var history = histories[session.id] ?? PortHistory()
            history.sampleCount += 1
            history.lastSeen = snapshot.timestamp
            if history.firstSeen == nil { history.firstSeen = snapshot.timestamp }

            for device in session.usbDevices {
                if let speed = device.speed?.bitsPerSecond {
                    history.maxUSBBitsPerSecond = max(history.maxUSBBitsPerSecond ?? 0, speed)
                }
            }

            if session.id == attributableID, let power = snapshot.power {
                if power.isCharging, let watts = power.watts {
                    history.maxChargingWatts = max(history.maxChargingWatts ?? 0, watts)
                }
                if power.pdContract?.implies5ACable == true {
                    history.saw5AContract = true
                }
            }

            histories[session.id] = history
        }
    }

    public func overallRating() -> CableRating {
        rating(from: histories.values.reduce(into: PortHistory()) { acc, h in
            acc.merge(h)
        })
    }

    public func rating(forSessionID sessionID: String) -> CableRating? {
        histories[sessionID].map(rating(from:))
    }

    /// 合并另一份引擎的历史（同 key 取峰值较大/窗口并集；sampleCount 取较大避免重复计数）。
    /// 合并是幂等的，用于 App/CLI 双存储的迁移归一。
    public mutating func merge(_ other: CableRatingEngine) {
        for (key, history) in other.histories {
            histories[key, default: PortHistory()].merge(history)
        }
    }

    private func rating(from history: PortHistory) -> CableRating {
        CableRating(
            maxUSBBitsPerSecond: history.maxUSBBitsPerSecond,
            maxChargingWatts: history.maxChargingWatts,
            is5ACable: history.saw5AContract,
            maxDisplayLinkRate: history.maxDisplayLinkRate,
            maxRefreshRateHz: history.maxRefreshRateHz,
            sampleCount: history.sampleCount,
            firstSeen: history.firstSeen,
            lastSeen: history.lastSeen
        )
    }

    // MARK: 持久化

    private struct Store: Codable {
        var version: Int = 2
        var histories: [String: PortHistory]
    }

    /// v1 旧格式：key 为完整 LocationID（0 号桶 = 无 USB 设备时的整机兜底）。
    /// 旧桶内数据是整机混合峰值，迁移时按 key >> 20 归入新会话桶，只保证峰值不缩水。
    private struct LegacyStore: Codable {
        var histories: [UInt32: PortHistory]
    }

    public func save(to url: URL) throws {
        let store = Store(histories: histories)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(store)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    public static func load(from url: URL) throws -> CableRatingEngine {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var engine = CableRatingEngine()
        if let store = try? decoder.decode(Store.self, from: data) {
            engine.histories = store.histories
            return engine
        }

        // v1 → v2 迁移：LocationID >> 20 映射为会话 id；0 号桶（整机兜底）→ "sys"。
        // 多个旧 key 可能坍缩到同一会话，需按峰值合并且不可用 uniqueKeysWithValues。
        let legacy = try decoder.decode(LegacyStore.self, from: data)
        var migrated: [String: PortHistory] = [:]
        for (locationID, history) in legacy.histories {
            let key = locationID == 0 ? systemKey : PortGrouping.sessionID(forPortKey: locationID >> 20)
            migrated[key, default: PortHistory()].merge(history)
        }
        engine.histories = migrated
        return engine
    }
}
