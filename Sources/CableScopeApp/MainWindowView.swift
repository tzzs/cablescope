import SwiftUI

/// 主窗口（方案 A）：状态头部 + 整机概览卡 + 线缆卡片行 + 选中线详情卡。
/// 电池 / 输入功率 / 显示器属于整机区；每根线缆一张卡片，点选后下方展示该线详情。
struct MainWindowView: View {
    @ObservedObject var viewModel: MonitorViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HeaderView(viewModel: viewModel)
                OverviewSectionView(viewModel: viewModel)
                CableCardsSectionView(viewModel: viewModel)
                SessionDetailSectionView(viewModel: viewModel)
                ThroughputSectionView()
            }
            .padding(16)
        }
        .task { viewModel.start() }
    }
}

// MARK: - 状态头部

private struct HeaderView: View {
    @ObservedObject var viewModel: MonitorViewModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("CableScope")
                    .font(.title2.weight(.semibold))
                if let timestamp = viewModel.snapshot?.timestamp {
                    Text("最近快照 \(timestamp.formatted(date: .omitted, time: .standard))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    Text("等待首次快照…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            ChargingBadge(isCharging: viewModel.isCharging,
                          isConnected: viewModel.isExternalConnected,
                          hasData: viewModel.snapshot != nil)
            Button {
                openWindow(id: "registry")
                NSApplication.shared.activate(ignoringOtherApps: true)
            } label: {
                Label("IOKit 属性", systemImage: "list.bullet.rectangle.portrait")
            }
            .keyboardShortcut("i", modifiers: .command)
            Button {
                viewModel.refresh()
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
                    // 采集中图标脉冲替代独立进度圈（.rotate 需 macOS 15，取 14 可用的 pulse）；
                    // Reduce Motion 下静止。
                    .symbolEffect(.pulse, options: .repeating,
                                  isActive: viewModel.isRefreshing && !reduceMotion)
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(viewModel.isRefreshing)
        }
    }
}
