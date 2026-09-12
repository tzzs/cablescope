import SwiftUI

/// 菜单栏状态项 label：图标 + 动态功率文字（充电中 "⚡65W"，无数据 "⚡--"）。
/// 独立 View + @ObservedObject，保证 VM 变化时状态项文字实时刷新。
struct MenuBarLabelView: View {
    @ObservedObject var viewModel: MonitorViewModel

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: viewModel.isCharging ? "bolt.fill" : "cable.connector")
                .imageScale(.small)
            Text(viewModel.menuLabel)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .monospacedDigit()
        }
    }
}

/// 菜单栏弹出面板（.window 样式）：功率大字、电量、最新 USB 速率、打开主窗口、退出。
struct MenuBarPanelView: View {
    @ObservedObject var viewModel: MonitorViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("CableScope", systemImage: "cable.connector")
                    .font(.headline)
                Spacer()
                ChargingBadge(isCharging: viewModel.isCharging, hasData: viewModel.snapshot != nil)
            }

            // 当前功率大字
            VStack(alignment: .leading, spacing: 2) {
                if let watts = viewModel.displayWatts {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(watts, format: .number.precision(.fractionLength(1)))")
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Text("W")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("暂无充电数据")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Text("当前充电功率")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // 电量 + 最新 USB 速率
            VStack(alignment: .leading, spacing: 8) {
                if let percent = viewModel.snapshot?.power?.batteryPercent {
                    HStack(spacing: 8) {
                        Image(systemName: BatteryGlyph.symbol(for: percent))
                            .foregroundStyle(.secondary)
                        ProgressView(value: percent.clamped(to: 0...100) / 100)
                            .frame(width: 90)
                        Text("\(Int(percent.rounded()))%")
                            .font(.callout)
                            .monospacedDigit()
                    }
                }
                HStack(spacing: 6) {
                    Text("USB")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let speed = viewModel.topUSBSpeed {
                        SpeedBadge(speed: speed)
                    } else {
                        Text("无设备")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Divider()

            MenuRowButton(title: "打开 CableScope", systemImage: "macwindow") {
                openWindow(id: "main")
                // accessory 形态下打开窗口后主动激活，避免窗口出现在后台。
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            MenuRowButton(title: "退出", systemImage: "power") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(12)
        .frame(width: 250, alignment: .leading)
        .task { viewModel.start() }
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
