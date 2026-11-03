import Foundation

// MARK: - 充电概览组装（纯函数，可单测）
//
// 桌面小组件（`CableScopeWidget`）与主窗口需要展示同一批派生量：充电功率、端口头条、
// 电池电量、是否充电。这些量的**组装规则**（哪条端口头条置顶、功率何时算作"正在充"、
// 什么情况算"没有数据"）是业务逻辑，不是 UI 代码——放在 Widget target 里既无法被
// `swift test` 覆盖（Widget 是 Xcode-only target，不在 Package.swift 里），也让同一条
// 规则在 App 与 Widget 两处各写一遍、各自漂移。
//
// 故规则收进 CableKit 的纯函数，Widget/App 只负责把结果渲染成视图。

/// 充电概览：一次采集得到的全部派生量。
///
/// 全部字段可缺省——IOKit 读取受限时逐项降级，**任何一项失败都不让整体崩掉**。
///
/// **这是渲染产物，不是快照。** `topPortHeadline` / `portHeadlines` 是按 locale
/// 现算好的文案（与 `CableSnapshot` 这类 `Codable` 值类型不同，本类型不可 `Codable`、
/// 不可持久化）——语言偏好变了就得重算，缓存或存盘都会把语言冻结在生成的那一刻。
/// 需要结构化数据时请用 `PowerSnapshot` / `USBCPortSnapshot` 本身。
public struct ChargingOverview: Equatable, Sendable {
    /// 电池充电功率 W（流入电池的功率，仅充电中且读数 > 0）。
    public let watts: Double?
    /// 端口控制器选中的 PD 档位功率 W（WinningPowerSourceOption 的 `Max Power`，取各端口最大值）。
    ///
    /// 这是**充电器广告档位的上限**，不是实际输出、也不是合同电流——展示时只能
    /// 说"档位/协商档"，不能说"正在以 XW 充电"。
    public let winningPDOWatts: Double?
    /// 置顶端口头条（优先正在收电的端口）。
    public let topPortHeadline: String?
    /// 每端口一行头条（medium 布局用）。
    public let portHeadlines: [String]
    /// 电池电量 0-100。
    public let batteryPercent: Double?
    /// 正在充电（IsCharging）。
    public let isCharging: Bool
    /// 适配器已接通（ExternalConnected，无论是否在充）。
    public let externalConnected: Bool
    /// 是否采集到有效数据；false → 展示占位。
    public let hasData: Bool

    public init(watts: Double? = nil,
                winningPDOWatts: Double? = nil,
                topPortHeadline: String? = nil,
                portHeadlines: [String] = [],
                batteryPercent: Double? = nil,
                isCharging: Bool = false,
                externalConnected: Bool = false,
                hasData: Bool = false) {
        self.watts = watts
        self.winningPDOWatts = winningPDOWatts
        self.topPortHeadline = topPortHeadline
        self.portHeadlines = portHeadlines
        self.batteryPercent = batteryPercent
        self.isCharging = isCharging
        self.externalConnected = externalConnected
        self.hasData = hasData
    }
}

public enum ChargingOverviewBuilder {
    /// 组合两路读取 → 概览。单路失败只降级对应字段。
    ///
    /// - Parameters:
    ///   - power: 电源快照（nil 表示读不到）。
    ///   - ports: 端口控制器快照（空数组表示读不到）。
    ///   - locale: 头条文案的语言。
    /// - Returns: 组装好的概览。电源与端口都读不到时 `hasData == false`（占位）。
    public static func build(power: PowerSnapshot?,
                             ports: [USBCPortSnapshot],
                             locale: Locale = .current) -> ChargingOverview {
        guard power != nil || !ports.isEmpty else {
            return ChargingOverview()
        }

        // 端口头条：medium 逐行展示；置顶条优先取正在收电（winning）的端口。
        let headlines = ports.compactMap {
            DiagnosticsEngine.portHeadline(port: $0, locale: locale)
        }
        let winningPort = ports.first { $0.powerSource?.winning != nil }
        let topHeadline = DiagnosticsEngine.portHeadline(port: winningPort, locale: locale)
            ?? headlines.first

        return ChargingOverview(
            watts: chargingWatts(power),
            winningPDOWatts: ports.compactMap { $0.powerSource?.winning?.watts }.max(),
            topPortHeadline: topHeadline,
            portHeadlines: headlines,
            batteryPercent: power?.batteryPercent,
            isCharging: power?.isCharging ?? false,
            externalConnected: power?.externalConnected ?? false,
            hasData: true
        )
    }

    /// 电池充电功率展示语义（对齐 App 的 `MonitorViewModel.displayWatts`）：
    /// 仅充电中且读数 > 0；保温暂停时电池电流为负，自然落入 nil。
    ///
    /// 注意量纲：这是**电池侧**功率（电池电压 × 电池电流），不是线缆/适配器输出。
    /// macOS 不提供端口级实测功率，UI 不得把它称作"充电器输出"。
    public static func chargingWatts(_ power: PowerSnapshot?) -> Double? {
        guard let power, power.isCharging, let watts = power.watts, watts > 0 else { return nil }
        return watts
    }
}
