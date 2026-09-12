import Foundation

/// 评级引擎默认实现：按 LocationID 聚合历史快照峰值（纯 Swift，无 IOKit 依赖，可单测）。
///
/// 关键规则见 Docs/03-数据获取指南.md：
/// - PD 合同 ≥ 20V/5A ⇒ e-marker 5A 线
/// - USB 协商速率取历史峰值（峰值只会抬高评级，不会因拔线清零）
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
    }

    /// key: LocationID（0 表示"未知端口"的聚合桶）
    private var histories: [UInt32: PortHistory] = [:]

    public init() {}

    public mutating func record(_ snapshot: CableSnapshot) {
        let usbDevices = snapshot.usbDevices
        let locations = usbDevices.map(\.locationID)
        // 整机快照可能没有 USB 设备但仍有电源/显示器信息：归入 0 号桶
        let primaryLocation: UInt32 = locations.first ?? 0

        var history = histories[primaryLocation] ?? PortHistory()
        history.sampleCount += 1
        history.lastSeen = snapshot.timestamp
        if history.firstSeen == nil { history.firstSeen = snapshot.timestamp }

        for device in usbDevices {
            if let speed = device.speed?.bitsPerSecond {
                history.maxUSBBitsPerSecond = max(history.maxUSBBitsPerSecond ?? 0, speed)
            }
        }

        if let power = snapshot.power, power.isCharging, let watts = power.watts {
            history.maxChargingWatts = max(history.maxChargingWatts ?? 0, watts)
        }
        if let contract = snapshot.power?.pdContract, contract.implies5ACable {
            history.saw5AContract = true
        }

        for display in snapshot.displays {
            if let hz = display.refreshRateHz {
                history.maxRefreshRateHz = max(history.maxRefreshRateHz ?? 0, hz)
            }
            if let link = display.linkRateLabel, history.maxDisplayLinkRate == nil || link > (history.maxDisplayLinkRate ?? "") {
                history.maxDisplayLinkRate = link
            }
        }

        histories[primaryLocation] = history
    }

    public func overallRating() -> CableRating {
        rating(from: histories.values.reduce(into: PortHistory()) { acc, h in
            if let v = h.maxUSBBitsPerSecond {
                acc.maxUSBBitsPerSecond = max(acc.maxUSBBitsPerSecond ?? 0, v)
            }
            if let w = h.maxChargingWatts {
                acc.maxChargingWatts = max(acc.maxChargingWatts ?? 0, w)
            }
            acc.saw5AContract = acc.saw5AContract || h.saw5AContract
            acc.maxDisplayLinkRate = [acc.maxDisplayLinkRate, h.maxDisplayLinkRate].compactMap { $0 }.max()
            if let hz = h.maxRefreshRateHz {
                acc.maxRefreshRateHz = max(acc.maxRefreshRateHz ?? 0, hz)
            }
            acc.sampleCount += h.sampleCount
            acc.firstSeen = [acc.firstSeen, h.firstSeen].compactMap { $0 }.min()
            acc.lastSeen = [acc.lastSeen, h.lastSeen].compactMap { $0 }.max()
        })
    }

    public func rating(forLocationID locationID: UInt32) -> CableRating? {
        histories[locationID].map(rating(from:))
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
        let store = try decoder.decode(Store.self, from: data)
        var engine = CableRatingEngine()
        engine.histories = store.histories
        return engine
    }
}
