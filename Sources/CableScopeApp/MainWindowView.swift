import SwiftUI

/// 主窗口：状态头部 + 充电 / 数据传输 / 视频 / 线缆能力 四张分区卡。
struct MainWindowView: View {
    @ObservedObject var viewModel: MonitorViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HeaderView(viewModel: viewModel)
                ChargingPanelView(viewModel: viewModel)
                TransferPanelView(viewModel: viewModel)
                VideoPanelView(viewModel: viewModel)
                RatingCardView(viewModel: viewModel)
            }
            .padding(16)
        }
        .task { viewModel.start() }
    }
}

// MARK: - 状态头部

private struct HeaderView: View {
    @ObservedObject var viewModel: MonitorViewModel

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
            ChargingBadge(isCharging: viewModel.isCharging, hasData: viewModel.snapshot != nil)
            if viewModel.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            }
            Button {
                viewModel.refresh()
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .disabled(viewModel.isRefreshing)
        }
    }
}
