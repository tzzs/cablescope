import CableKit
import Foundation

/// App 侧唯一的跨场景状态源：菜单栏与主窗口共享同一实例。
///
/// 职责：
/// - 消费 `CableMonitor.snapshotStream()`，驱动全部 @Published 状态；
/// - 持有评级引擎，每次新快照 record + save（持久化到 app-ratings.json）；
/// - 以 1Hz 采样维护最近 5 分钟的功率历史（环形缓冲 300 点）。
@MainActor
final class MonitorViewModel: ObservableObject {
    /// 功率曲线采样点。watts 为 NaN 表示当时无功率数据（折线在此断开）。
    struct PowerPoint: Identifiable, Equatable {
        let date: Date
        let watts: Double

        var id: Date { date }
        var isFinite: Bool { watts.isFinite }
    }

    static let historyCapacity = 300 // 1Hz × 5 分钟
    static let sampleIntervalNanos: UInt64 = 1_000_000_000

    // MARK: Published 状态

    @Published private(set) var snapshot: CableSnapshot?
    @Published private(set) var rating: CableRating?
    @Published private(set) var powerHistory: [PowerPoint] = []
    @Published private(set) var hasPowerData = false
    @Published private(set) var isRefreshing = false

    // MARK: 依赖

    private let monitor: CableMonitor
    private var ratingEngine: CableRatingEngine
    private let ratingsURL: URL

    // MARK: 后台任务

    private var streamTask: Task<Void, Never>?
    private var sampleTask: Task<Void, Never>?

    init(monitor: CableMonitor = CableMonitor(), ratingsURL: URL? = nil) {
        self.monitor = monitor
        self.ratingsURL = ratingsURL ?? Self.defaultRatingsURL()
        if let restored = try? CableRatingEngine.load(from: self.ratingsURL) {
            self.ratingEngine = restored
        } else {
            self.ratingEngine = CableRatingEngine()
        }
        self.rating = ratingEngine.overallRating()
    }

    deinit {
        streamTask?.cancel()
        sampleTask?.cancel()
    }

    // MARK: - 生命周期

    /// 幂等启动：消费快照流 + 1Hz 功率采样。启动时由 App 调用一次。
    func start() {
        guard streamTask == nil else { return }

        let monitor = self.monitor
        streamTask = Task { [weak self] in
            for await snapshot in monitor.snapshotStream() {
                guard let self else { break }
                self.ingest(snapshot)
            }
        }

        sampleTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                self.appendPowerSample()
                try? await Task.sleep(nanoseconds: Self.sampleIntervalNanos)
            }
        }
    }

    /// 手动刷新：立即采集一次快照（同样进入评级与 UI）。
    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task { [weak self] in
            guard let self else { return }
            let snapshot = try? await self.monitor.snapshotNow()
            if let snapshot {
                self.ingest(snapshot)
            }
            self.isRefreshing = false
        }
    }

    // MARK: - 派生状态（菜单栏与主窗口共用）

    var isCharging: Bool { snapshot?.power?.isCharging ?? false }

    /// 当前充电功率（仅充电中且读数 > 0 时有效）。
    var displayWatts: Double? {
        guard let power = snapshot?.power, power.isCharging,
              let watts = power.watts, watts > 0 else { return nil }
        return watts
    }

    /// 菜单栏标题："⚡65W" / "⚡--"。
    var menuLabel: String {
        if let watts = displayWatts {
            return String(format: "⚡%.0fW", watts)
        }
        return "⚡--"
    }

    /// 当前协商到的最高 USB 速率（"最新 USB 速率"）。
    var topUSBSpeed: USBSpeed? {
        snapshot?.usbDevices
            .compactMap(\.speed)
            .max { $0.bitsPerSecond < $1.bitsPerSecond }
    }

    /// 功率曲线分段：NaN（无数据）断开后的连续段，段与段之间不连线。
    var powerSegments: [[PowerPoint]] {
        var segments: [[PowerPoint]] = []
        var current: [PowerPoint] = []
        for point in powerHistory {
            if point.isFinite {
                current.append(point)
            } else if !current.isEmpty {
                segments.append(current)
                current = []
            }
        }
        if !current.isEmpty {
            segments.append(current)
        }
        return segments
    }

    // MARK: - 内部

    private func ingest(_ snapshot: CableSnapshot) {
        self.snapshot = snapshot

        // 评级：记录 + 持久化（引擎按 LocationID 聚合历史峰值，落盘到 app-ratings.json）。
        ratingEngine.record(snapshot)
        rating = ratingEngine.overallRating()
        do {
            try ratingEngine.save(to: ratingsURL)
        } catch {
            // 持久化失败不影响 UI，下次快照会重试。
        }
    }

    private func appendPowerSample() {
        let watts: Double
        switch snapshot?.power {
        case .none:
            watts = .nan // 尚无电源数据 → 折线断开
        case .some(let power) where !power.isCharging:
            watts = 0 // 未充电
        case .some(let power):
            watts = power.watts ?? .nan // 充电中但电压/电流读数缺失
        }

        powerHistory.append(PowerPoint(date: Date(), watts: watts))
        if powerHistory.count > Self.historyCapacity {
            powerHistory.removeFirst(powerHistory.count - Self.historyCapacity)
        }
        if watts.isFinite {
            hasPowerData = true
        }
    }

    private static func defaultRatingsURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("CableScope/app-ratings.json")
    }
}
