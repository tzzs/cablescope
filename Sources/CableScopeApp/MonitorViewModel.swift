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
    /// 当前选中的线缆会话（CableSession.id）；nil = 回退默认（第一根）。
    @Published private(set) var selectedSessionID: String?

    // MARK: 依赖

    private let monitor: CableMonitor
    private var ratingEngine: CableRatingEngine
    private let ratingsURL: URL
    private let notifications = NotificationController()

    // MARK: 后台任务

    private var streamTask: Task<Void, Never>?
    private var sampleTask: Task<Void, Never>?

    init(monitor: CableMonitor = CableMonitor(), ratingsURL: URL? = nil) {
        self.monitor = monitor
        self.ratingsURL = ratingsURL ?? RatingStore.canonicalURL
        // RatingStore 内含旧 app-ratings.json 的幂等迁移（App/CLI 统一到 ratings.json）。
        self.ratingEngine = RatingStore.loadEngine()
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

    /// 适配器已接通（无论是否正在充电，见 PowerSnapshot.externalConnected）。
    var isExternalConnected: Bool { snapshot?.power?.externalConnected ?? false }

    /// 当前充电功率（仅充电中且读数 > 0 时有效；保温暂停时 Amperage 为负，自然落入 nil）。
    var displayWatts: Double? {
        guard let power = snapshot?.power, power.isCharging,
              let watts = power.watts, watts > 0 else { return nil }
        return watts
    }

    /// 当前协商到的最高 USB 速率（"最新 USB 速率"）。
    var topUSBSpeed: USBSpeed? {
        snapshot?.usbDevices
            .compactMap(\.speed)
            .max { $0.bitsPerSecond < $1.bitsPerSecond }
    }

    // MARK: - 线缆会话（多线缆 UI 的一等公民）

    /// 按物理端口聚合的线缆会话（快照采集时由 PortGrouping 组装）。
    var sessions: [CableSession] { snapshot?.sessions ?? [] }

    /// 当前选中的会话；选择失效（拔线）或尚未选择时回退第一根。
    var selectedSession: CableSession? {
        sessions.first { $0.id == selectedSessionID } ?? sessions.first
    }

    /// 整机电源数据归属到指定会话（nil = 不可归属，充电信息只在整机概览展示）。
    /// 归属规则见 PortGrouping.attributablePowerSessionID：单线无歧义；多线时恰好一个
    /// 活跃端口在收电（powerSource.winning）才归属该端口，避免把充电数据记到别的线上。
    func power(for session: CableSession) -> PowerSnapshot? {
        guard let snapshot else { return nil }
        let ownerID = PortGrouping.attributablePowerSessionID(sessions: snapshot.sessions,
                                                              ports: snapshot.ports,
                                                              power: snapshot.power)
        return ownerID == session.id ? snapshot.power : nil
    }

    /// 切换选中的线缆会话（nil = 回退默认选择）。
    func selectSession(_ id: String?) {
        selectedSessionID = id
    }

    /// 方向键在卡片间移动选中（键盘可达性）；越界后循环。
    func selectAdjacentSession(offset: Int) {
        let ids = sessions.map(\.id)
        guard !ids.isEmpty else { return }
        let current = ids.firstIndex { $0 == selectedSessionID } ?? 0
        selectedSessionID = ids[(current + offset + ids.count) % ids.count]
    }

    /// 指定线缆会话的历史评级（端口峰值不清零）。
    func rating(forSessionID sessionID: String) -> CableRating? {
        ratingEngine.rating(forSessionID: sessionID)
    }

    // MARK: - 端口控制器数据（AppleHPM 直读）

    /// 会话对应的端口控制器快照（USB 会话按 physicalPortID 配对；雷雳会话 v1 暂无对应关系）。
    func port(for session: CableSession) -> USBCPortSnapshot? {
        guard let physicalPortID = session.physicalPortID else { return nil }
        return snapshot?.ports.first { $0.portID == physicalPortID }
    }

    /// 会话对应的外接显示器：先按物理端口精确匹配 DisplayPort 传输链路（PortGrouping.
    /// displayPortLinks），再按 EDID 身份把链路匹配到具体的 CGDirectDisplayID（PortGrouping.
    /// matchedDisplay），取到分辨率/刷新率。display 为 nil 时仍返回 link 本身——至少能展示
    /// 厂商/型号/链路速率，只是分辨率/刷新率这层匹配不唯一时留空，不瞎连。
    func displayLinks(for session: CableSession) -> [(link: DisplayPortLinkSnapshot, display: DisplaySnapshot?)] {
        guard let snapshot else { return [] }
        return PortGrouping.displayPortLinks(for: session, links: snapshot.displayPortLinks)
            .map { link in (link, PortGrouping.matchedDisplay(for: link, in: snapshot.displays)) }
    }

    /// 当前协商档的功率（WinningPowerSourceOption；未协商/无端口数据时为 nil）。
    var negotiatedPDOVoltageMV: Int? {
        snapshot?.ports.compactMap { $0.powerSource?.winning?.voltageMV }.max()
    }

    var negotiatedPDOWatts: Double? {
        snapshot?.ports.compactMap { $0.powerSource?.winning?.watts }.max()
    }

    /// 充电瓶颈诊断（派生自当前快照，纯展示）。
    var chargingDiagnostics: ChargingDiagnostics? {
        guard let power = snapshot?.power else { return nil }
        return DiagnosticsEngine.diagnoseCharging(power: power,
                                                  adapterMaxWatts: negotiatedPDOWatts,
                                                  locale: AppPreferences.effectiveLocale())
    }

    /// 展示用的 PD 档位来源：优先取正在协商的端口，否则取档位最多的一份。
    var activePDO: PDOPortPowerSnapshot? {
        let sources = snapshot?.ports.compactMap(\.powerSource) ?? []
        return sources.first { $0.winning != nil }
            ?? sources.max { $0.options.count < $1.options.count }
    }

    /// 近 5 分钟是否出现过非零功率。未充电时采样全为 0，画出来是无意义的平线。
    var hasNonZeroPower: Bool {
        powerHistory.contains { $0.isFinite && $0.watts > 0.01 }
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

        // 选中会话被拔除时自动回退到第一根，避免详情区悬空。
        if let current = selectedSessionID, !snapshot.sessions.contains(where: { $0.id == current }) {
            selectedSessionID = snapshot.sessions.first?.id
        }

        // 评级：记录 + 持久化（引擎按线缆会话聚合历史峰值，落盘到统一 ratings.json）。
        ratingEngine.record(snapshot)
        rating = ratingEngine.overallRating()
        do {
            try ratingEngine.save(to: ratingsURL)
        } catch {
            // 持久化失败不影响 UI，下次快照会重试。
        }

        // 线缆变化通知（插拔 + 状态变化）：内容有变化才到 ingest；ratingEngine 已完成
        // 本次 record，传的是记录后的最新评级。
        notifications.process(snapshot: snapshot, ratingEngine: ratingEngine, port: { self.port(for: $0) })
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
}
