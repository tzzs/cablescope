import Charts
import SwiftUI

/// 🖥 视频面板：显示器列表 + 实时功率曲线（Swift Charts）。
struct VideoPanelView: View {
    @ObservedObject var viewModel: MonitorViewModel

    var body: some View {
        SectionCard(title: "视频", systemImage: "display") {
            displayList

            // 只在有功率数据时展示实时曲线
            if viewModel.hasPowerData {
                Divider()
                powerChartSection
            }
        }
    }

    // MARK: 显示器列表

    @ViewBuilder
    private var displayList: some View {
        let displays = viewModel.snapshot?.displays ?? []
        if viewModel.snapshot == nil {
            EmptyHint(text: "等待首次快照…")
        } else if displays.isEmpty {
            EmptyHint(text: "未检测到外接显示器")
        } else {
            VStack(spacing: 8) {
                ForEach(displays) { display in
                    HStack(spacing: 10) {
                        Image(systemName: display.isMain ? "display.2" : "display")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(display.name ?? "显示器")
                                    .font(.callout.weight(.medium))
                                if display.isMain {
                                    InfoChip(text: "主显示器", systemImage: "star.fill", color: .blue)
                                }
                            }
                            HStack(spacing: 8) {
                                Text(display.resolutionLabel)
                                if let refreshRateHz = display.refreshRateHz {
                                    Text(String(format: "%.0f Hz", refreshRateHz))
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        }
                        Spacer()
                        if let linkRateLabel = display.linkRateLabel {
                            InfoChip(text: linkRateLabel, systemImage: "link", color: .indigo)
                        }
                    }
                }
            }
        }
    }

    // MARK: 实时功率曲线（近 5 分钟）

    private var powerChartSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("实时功率（近 5 分钟）")
                    .font(.subheadline.weight(.medium))
                Spacer()
                if let watts = viewModel.displayWatts {
                    Text(String(format: "%.1f W", watts))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.orange)
                        .monospacedDigit()
                }
            }
            PowerChart(segments: viewModel.powerSegments)
                .frame(height: 130)
        }
    }
}

/// 最近 5 分钟功率折线。NaN 断点已在 ViewModel 分段，段与段之间不连线。
struct PowerChart: View {
    let segments: [[MonitorViewModel.PowerPoint]]

    var body: some View {
        Chart {
            ForEach(segments.indices, id: \.self) { index in
                ForEach(segments[index]) { point in
                    LineMark(
                        x: .value("时间", point.date),
                        y: .value("功率", point.watts)
                    )
                }
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .foregroundStyle(Color.orange)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4))
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3))
        }
    }
}
