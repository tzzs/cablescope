import CableKit
import SwiftUI

/// ⚡ 充电面板：大号功率、电压/电流、PD 合同、电量进度条、循环次数。
struct ChargingPanelView: View {
    @ObservedObject var viewModel: MonitorViewModel

    var body: some View {
        SectionCard(title: "充电", systemImage: "bolt.fill") {
            if let power = viewModel.snapshot?.power {
                VStack(alignment: .leading, spacing: 12) {
                    powerHeader(power)

                    if let voltageMV = power.adapterVoltageMV, let amperageMA = power.adapterAmperageMA {
                        HStack(spacing: 16) {
                            MetricLabel(title: "电压", value: String(format: "%.1f V", Double(voltageMV) / 1000))
                            MetricLabel(title: "电流", value: String(format: "%.2f A", Double(amperageMA) / 1000))
                        }
                    }

                    if let contract = power.pdContract {
                        HStack(spacing: 8) {
                            InfoChip(
                                text: String(
                                    format: "PD 合同 %.0fV / %.1fA · %.0fW",
                                    Double(contract.voltageMV) / 1000,
                                    Double(contract.currentMA) / 1000,
                                    contract.watts
                                ),
                                systemImage: "bolt.fill",
                                color: .blue
                            )
                            if contract.implies5ACable {
                                InfoChip(text: "5A e-marker 线", systemImage: "checkmark.seal.fill", color: .orange)
                            }
                        }
                    }

                    batterySection(power)

                    if let description = power.adapterDescription, !description.isEmpty {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                EmptyHint(text: "暂无数据")
            }
        }
    }

    // MARK: 大号功率数字

    @ViewBuilder
    private func powerHeader(_ power: PowerSnapshot) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let watts = viewModel.displayWatts {
                Text("\(watts, format: .number.precision(.fractionLength(1)))")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("W")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            } else if !power.isCharging {
                Text("未在充电")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)
            } else {
                Text("暂无数据")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "bolt.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(viewModel.isCharging ? Color.orange : Color.secondary)
        }
    }

    // MARK: 电量进度条 + 循环次数

    @ViewBuilder
    private func batterySection(_ power: PowerSnapshot) -> some View {
        if let percent = power.batteryPercent {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("电量", systemImage: BatteryGlyph.symbol(for: percent))
                        .font(.callout)
                    Spacer()
                    Text("\(Int(percent.rounded()))%")
                        .font(.callout.weight(.semibold))
                        .monospacedDigit()
                }
                ProgressView(value: percent.clampedToBatteryFraction)
                    .progressViewStyle(.linear)
                    .tint(percent <= 20 ? Color.red : Color.accentColor)
                if let cycleCount = power.cycleCount {
                    Text("电池循环次数：\(cycleCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else if let cycleCount = power.cycleCount {
            Text("电池循环次数：\(cycleCount)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private extension Double {
    /// 0-100 的电量百分比 → 0-1（越界值截断，防止 ProgressView 越界）。
    var clampedToBatteryFraction: Double {
        min(max(self, 0), 100) / 100
    }
}
