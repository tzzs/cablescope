import CableKit
import Charts
import SwiftUI

/// 整机概览卡：系统输入功率大字 + 近 5 分钟曲线 + 电池 + PD 合同 + 显示器 + 整机评级。
///
/// 这些数据本质属于整机：显示器与多线缆时的充电信息无法按线归属（数据源限制），
/// 固定挂这里；仅接一根线时充电状态会同时提升到该线卡片展示。
struct OverviewSectionView: View {
    @ObservedObject var viewModel: MonitorViewModel
    @Environment(\.locale) private var locale

    var body: some View {
        SectionCard(title: "整机概览", systemImage: "desktopcomputer",
                    caption: "电池 · 输入功率 · 显示器 — 不随选中线变化") {
            if let power = viewModel.snapshot?.power {
                HStack(alignment: .top, spacing: 20) {
                    powerColumn(power)
                    batteryColumn(power)
                }
            } else if viewModel.snapshot == nil {
                EmptyHint(text: "等待首次快照…")
            } else {
                EmptyHint(text: "暂无电源数据")
            }

            pdoFooter
            displayFooter
            ratingFooter
        }
    }

    // MARK: 左列：功率大字 + 曲线

    private func powerColumn(_ power: PowerSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let watts = viewModel.displayWatts {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(watts, format: .number.precision(.fractionLength(1)))")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("W")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            } else if power.externalConnected {
                // 已接通但未充电：电池保温/优化充电暂停（IsCharging=false）或有读数缺失
                Text("已接通电源")
                    .font(.title3.weight(.medium))
            } else {
                Text("使用电池")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            if let voltageMV = power.adapterVoltageMV, let amperageMA = power.adapterAmperageMA {
                // 固定文案片段和数值分开：数值走 FormatStyle 插值，不经过字符串目录查表
                // （Swift 给 FormatStyle 插值生成的 key 格式没有把握，不敢手写对应译文，
                // 之前直接整句插值导致这行文字永远显示中文，语言切换对它没有效果）。
                (Text("系统输入 · ")
                    + Text(Double(voltageMV) / 1000, format: .number.precision(.fractionLength(1)))
                    + Text("V / ")
                    + Text(Double(amperageMA) / 1000, format: .number.precision(.fractionLength(2)))
                    + Text("A"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            chargingDiagnosticRow

            if viewModel.hasNonZeroPower {
                PowerChart(segments: viewModel.powerSegments)
                    .frame(height: 60)
                    .padding(.top, 6)
                    .accessibilityLabel("最近 5 分钟功率曲线")
                Text("最近 5 分钟功率曲线")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if viewModel.isExternalConnected {
                Text("当前未在充电 · 暂无功率变化")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 充电诊断（归因结论，端口控制器数据可用时含"线缆可能受限"分支）

    @ViewBuilder
    private var chargingDiagnosticRow: some View {
        if let diagnostics = viewModel.chargingDiagnostics {
            VStack(alignment: .leading, spacing: 2) {
                Label(diagnostics.summary, systemImage: Self.diagnosticIcon(diagnostics.verdict))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Self.diagnosticColor(diagnostics.verdict))
                if let detail = diagnostics.detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 2)
        }
    }

    private static func diagnosticIcon(_ verdict: ChargingBottleneck) -> String {
        switch verdict {
        case .adapterMax: return "checkmark.circle.fill"
        case .machineDrawingLess: return "battery.75"
        case .cableLikelyLimited: return "exclamationmark.triangle.fill"
        case .paused: return "moon.zzz.fill"
        case .notConnected: return "bolt.slash"
        case .unknown: return "questionmark.circle"
        }
    }

    private static func diagnosticColor(_ verdict: ChargingBottleneck) -> Color {
        switch verdict {
        case .adapterMax: return .green
        case .machineDrawingLess: return .blue
        case .cableLikelyLimited: return .orange
        case .paused: return .blue
        case .notConnected: return .secondary
        case .unknown: return .secondary
        }
    }

    // MARK: PD 档位表（端口控制器直读，当前协商档高亮）

    @ViewBuilder
    private var pdoFooter: some View {
        if let pdo = viewModel.activePDO, !pdo.options.isEmpty {
            Divider()
            PDOOptionsView(pdo: pdo, sourceLabel: pdo.sourceName)
        }
    }

    // MARK: 右列：电池 + PD 合同（统一键值行：左侧图标+标题，右侧数值，保证多行对齐）

    private func batteryColumn(_ power: PowerSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let percent = power.batteryPercent {
                kvRow(icon: BatteryGlyph.symbol(for: percent), title: "电量") {
                    Text("\(Int(percent.rounded()))%")
                        .font(.callout.weight(.semibold))
                        .monospacedDigit()
                }
                ProgressView(value: percent.clampedToBatteryFraction)
                    .progressViewStyle(.linear)
                    .tint(percent <= 20 ? Color.red : Color.accentColor)
                    .accessibilityHidden(true) // 电量数值已由上方 kv 行朗读，避免重复
            }
            if let cycleCount = power.cycleCount {
                kvRow(icon: "arrow.triangle.2.circlepath", title: "电池循环") {
                    Text("\(cycleCount) 次")
                        .font(.callout.weight(.semibold))
                        .monospacedDigit()
                }
            }
            if let contract = power.pdContract {
                kvRow(icon: "bolt.fill", title: "PD 合同") {
                    InfoChip(
                        verbatim: String(
                            format: "%.0fV / %.1fA · %.0fW",
                            Double(contract.voltageMV) / 1000,
                            Double(contract.currentMA) / 1000,
                            contract.watts
                        ),
                        color: .blue
                    )
                }
                if contract.implies5ACable {
                    kvRow(icon: "checkmark.seal.fill", title: "线缆推断") {
                        InfoChip(text: "5A e-marker 线", color: .orange, isProminent: true)
                    }
                }
            }
            if let description = power.adapterDescription, !description.isEmpty {
                kvRow(icon: "powerplug.fill", title: "充电器") {
                    Text(Self.prettyAdapterDescription(description))
                        .font(.callout)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 概览/详情共用的键值行：定宽图标列 + 标题，右侧任意视图（数值/胶囊）。
    /// 图标列固定宽度让多行标题纵向对齐（与样机 kv 行、显示器行的 18pt 列一致）。
    private func kvRow<Trailing: View>(icon: String, title: LocalizedStringKey,
                                       @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(title)
                .font(.callout)
            Spacer(minLength: 8)
            trailing()
        }
    }

    // MARK: 显示器（整机级，v1 不按线归属）

    @ViewBuilder
    private var displayFooter: some View {
        let displays = viewModel.snapshot?.displays ?? []
        if !displays.isEmpty {
            Divider()
            // Grid 而不是每行一个 HStack+Spacer：分辨率与刷新率各自独占一列，
            // 按列对齐而不是整串文字右对齐——"2940×1912·60Hz" 和 "3840×2160·144Hz"
            // 位数不一样，右对齐整串只会让 "×" 和 "Hz" 的位置继续错开。
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                ForEach(displays) { display in
                    GridRow {
                        HStack(spacing: 6) {
                            Image(systemName: display.isMain ? "display.2" : "display")
                                .foregroundStyle(.secondary)
                                .frame(width: 18)
                            Group {
                                if let name = display.name {
                                    Text(name)
                                } else {
                                    Text("显示器")
                                }
                            }
                                .font(.callout)
                                .lineLimit(1)
                            if display.isMain {
                                InfoChip(text: "主显示器", systemImage: "star.fill", color: .blue)
                            }
                        }
                        .gridCellColumns(1)

                        Text(display.resolutionLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .gridColumnAlignment(.trailing)

                        Group {
                            if let refreshRateHz = display.refreshRateHz {
                                Text("\(refreshRateHz, format: .number.precision(.fractionLength(0))) Hz")
                            } else {
                                Text("—")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .gridColumnAlignment(.trailing)

                        // 固定占一列，没有链路速率时用透明占位，避免这一行少一格
                        // 把后面列的对齐带偏（Grid 按位置分列，不是按内容分列）。
                        Group {
                            if let linkRateLabel = display.linkRateLabel {
                                InfoChip(verbatim: linkRateLabel, systemImage: "link", color: .indigo)
                            } else {
                                Color.clear.frame(width: 1, height: 1)
                            }
                        }
                        .gridColumnAlignment(.trailing)
                    }
                }
            }
        }
    }

    /// IOKit 原文适配器描述（充电器固件上报，如 "pd charger"）→ 展示文案：
    /// 词首大写 + 常见缩写全大写。仅 App 展示层美化；快照数据保持原文（CLI/JSON 不变）。
    static func prettyAdapterDescription(_ raw: String) -> String {
        let acronyms: Set<String> = ["pd", "usb", "usbc", "usb-c", "gan"]
        return raw.split(separator: " ").map { word in
            let lower = word.lowercased()
            if acronyms.contains(lower) { return lower.uppercased() }
            return word.prefix(1).uppercased() + word.dropFirst()
        }.joined(separator: " ")
    }

    // MARK: 整机评级（合并所有端口，胶囊样式）

    @ViewBuilder
    private var ratingFooter: some View {
        if let rating = viewModel.rating, rating.sampleCount > 0 {
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "star.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(width: 18)
                FlowLayout(spacing: 5) {
                    InfoChip(text: "整机评级 · \(rating.sampleCount) 次观测", color: .gray)
                    InfoChip(
                        verbatim: rating.summary(locale: locale),
                        color: rating.is5ACable ? .orange : .blue,
                        isProminent: rating.is5ACable
                    )
                }
            }
        }
    }
}

/// 最近 5 分钟功率极简折线（无坐标轴的 sparkline 风格，带渐变面积）。
/// NaN 断点已在 ViewModel 分段，段与段之间不连线。
struct PowerChart: View {
    let segments: [[MonitorViewModel.PowerPoint]]

    var body: some View {
        Chart {
            ForEach(segments.indices, id: \.self) { index in
                ForEach(segments[index]) { point in
                    AreaMark(
                        x: .value("时间", point.date),
                        y: .value("功率", point.watts)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(.linearGradient(
                        colors: [Color.orange.opacity(0.25), Color.orange.opacity(0.02)],
                        startPoint: .top, endPoint: .bottom
                    ))
                    LineMark(
                        x: .value("时间", point.date),
                        y: .value("功率", point.watts)
                    )
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(Color.orange)
                }
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
    }
}

private extension Double {
    /// 0-100 的电量百分比 → 0-1（越界值截断，防止 ProgressView 越界）。
    var clampedToBatteryFraction: Double {
        min(max(self, 0), 100) / 100
    }
}
