import CableKit
import SwiftUI
import WidgetKit

// MARK: - 数据采集（CableKit 精简读取）
//
// 设计取舍：
// - widget 进程里 IOKit 读取可能受限/降速：只用两路最便宜的数据
//   （PowerService().currentPower() + PortControllerService().listPorts()），
//   不拉 USB/显示器/雷雳全量快照。两个 Service 内部均已 Task.detached，await 不阻塞。
// - 每路独立 `try?` 容错，任何失败都降级为占位 entry，永不崩溃、永不抛出。
// - IOKit 是"现场读取"，不适合预生成多条未来 entry：时间线固定 1 条，
//   15 分钟后请求系统刷新（.after）。

/// 一次时间线采集的结果。字段全部可缺省（IOKit 受限时降级）。
struct ChargingEntry: TimelineEntry {
    let date: Date
    /// 当前充电功率 W（仅充电中且读数 > 0；语义同 App 的 MonitorViewModel.displayWatts）
    let watts: Double?
    /// 端口控制器 PD 协商档功率 W（WinningPowerSourceOption）
    let winningPDOWatts: Double?
    /// 置顶端口头条（优先正在收电的端口；来自 DiagnosticsEngine.portHeadline）
    let topPortHeadline: String?
    /// 每端口一行头条（medium 布局用）
    let portHeadlines: [String]
    /// 电池电量 0-100
    let batteryPercent: Double?
    /// 正在充电（IsCharging）
    let isCharging: Bool
    /// 适配器已接通（ExternalConnected，无论是否在充）
    let externalConnected: Bool
    /// 是否采集到有效数据；false → 占位 UI
    let hasData: Bool

    /// 占位 entry（采集失败 / 无数据 / 图库预览）。
    static func placeholder(date: Date) -> ChargingEntry {
        ChargingEntry(date: date, watts: nil, winningPDOWatts: nil, topPortHeadline: nil,
                      portHeadlines: [], batteryPercent: nil,
                      isCharging: false, externalConnected: false, hasData: false)
    }
}

struct ChargingProvider: TimelineProvider {
    /// 刷新间隔。
    static let refreshInterval: TimeInterval = 15 * 60

    func placeholder(in context: Context) -> ChargingEntry {
        .placeholder(date: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (ChargingEntry) -> Void) {
        // 图库预览用占位，避免真实 IOKit 采集拖慢展示。
        guard !context.isPreview else {
            completion(.placeholder(date: Date()))
            return
        }
        Task { completion(await Self.collectEntry(date: Date())) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ChargingEntry>) -> Void) {
        let date = Date()
        Task {
            let entry = await Self.collectEntry(date: date)
            let refresh = date.addingTimeInterval(Self.refreshInterval)
            completion(Timeline(entries: [entry], policy: .after(refresh)))
        }
    }

    // MARK: 采集

    /// 组合两路读取 → entry。单路失败只降级对应字段。
    static func collectEntry(date: Date) async -> ChargingEntry {
        async let powerTask = readPower()
        async let portsTask = readPorts()
        let power = await powerTask
        let ports = await portsTask

        guard power != nil || !ports.isEmpty else {
            return .placeholder(date: date)
        }

        // 端口头条：medium 逐行展示；置顶条优先取正在收电（winning）的端口。
        let headlines = ports.compactMap { DiagnosticsEngine.portHeadline(port: $0, power: power) }
        let winningPort = ports.first { $0.powerSource?.winning != nil }
        let topHeadline = DiagnosticsEngine.portHeadline(port: winningPort, power: power)
            ?? headlines.first

        return ChargingEntry(
            date: date,
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

    /// 充电功率展示语义（对齐 MonitorViewModel.displayWatts）：
    /// 仅充电中且读数 > 0；保温暂停时 Amperage 为负，自然落入 nil。
    private static func chargingWatts(_ power: PowerSnapshot?) -> Double? {
        guard let power, power.isCharging, let watts = power.watts, watts > 0 else { return nil }
        return watts
    }

    private static func readPower() async -> PowerSnapshot? {
        (try? await PowerService().currentPower()) ?? nil
    }

    private static func readPorts() async -> [USBCPortSnapshot] {
        (try? await PortControllerService().listPorts()) ?? []
    }
}

// MARK: - Widget 定义

struct CableScopeChargingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "CableScopeChargingWidget", provider: ChargingProvider()) { entry in
            ChargingWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("充电功率")
        .description("当前充电功率、PD 协商档与各端口线缆头条，约每 15 分钟刷新。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct ChargingWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ChargingEntry

    var body: some View {
        switch family {
        case .systemMedium:
            MediumContent(entry: entry)
        default:
            SmallContent(entry: entry)
        }
    }
}

// MARK: - small：功率大字 + 状态 + 电池电量条

private struct SmallContent: View {
    let entry: ChargingEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if entry.hasData {
                statusRow
                powerText
                if entry.watts == nil, let winning = entry.winningPDOWatts {
                    Text("协商档 \(Int(winning.rounded()))W")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            } else {
                Image(systemName: "cable.connector")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("打开 CableScope 查看线缆详情")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            batteryFooter
        }
    }

    /// 状态行：图标 + "充电中 / 已暂停 / 使用电池"。
    private var statusRow: some View {
        HStack(spacing: 4) {
            Image(systemName: iconName)
                .font(.caption)
                .foregroundStyle(iconTint)
            Text(statusLabel)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    /// 功率大字；未在充电时以文字状态代替（已接通电源 / 使用电池）。
    @ViewBuilder
    private var powerText: some View {
        if let watts = entry.watts {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(watts, format: .number.precision(.fractionLength(1)))
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text("W")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        } else if entry.externalConnected {
            Text("已接通电源")
                .font(.title3.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        } else {
            Text("使用电池")
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    /// 电池电量条（有读数才显示；≤20% 变红，语义同 App 概览）。
    @ViewBuilder
    private var batteryFooter: some View {
        if let percent = entry.batteryPercent {
            let clamped = min(max(percent, 0), 100)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Image(systemName: Self.batterySymbol(clamped))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(Int(clamped.rounded()))%")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(clamped <= 20 ? Color.red : Color.primary)
                }
                ProgressView(value: clamped / 100)
                    .progressViewStyle(.linear)
                    .tint(clamped <= 20 ? Color.red : Color.accentColor)
            }
        }
    }

    // MARK: 状态语汇（对齐 OverviewSectionView）

    private var statusLabel: String {
        if entry.isCharging { return "充电中" }
        if entry.externalConnected { return "已暂停" }
        return "使用电池"
    }

    private var iconName: String {
        switch (entry.isCharging, entry.externalConnected) {
        case (true, _): return "bolt.fill"
        case (false, true): return "moon.zzz.fill"
        case (false, false): return "battery.75"
        }
    }

    private var iconTint: Color {
        switch (entry.isCharging, entry.externalConnected) {
        case (true, _): return .green
        case (false, true): return .blue
        case (false, false): return .secondary
        }
    }

    private static func batterySymbol(_ percent: Double) -> String {
        switch percent {
        case 90...: return "battery.100"
        case 60..<90: return "battery.75"
        case 35..<60: return "battery.50"
        case 15..<35: return "battery.25"
        default: return "battery.0"
        }
    }
}

// MARK: - medium：左列 small 内容 + 右列每端口一行头条（≤3 行）

private struct MediumContent: View {
    let entry: ChargingEntry

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            SmallContent(entry: entry)
                .frame(width: 116, alignment: .leading)
            Divider()
            portColumn
        }
    }

    @ViewBuilder
    private var portColumn: some View {
        if entry.portHeadlines.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Label("暂无端口数据", systemImage: "questionmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("老机型或无 USB-C 控制器读数")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(entry.portHeadlines.prefix(3).enumerated()), id: \.offset) { _, headline in
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Image(systemName: "cable.connector")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(headline)
                            .font(.caption2)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
