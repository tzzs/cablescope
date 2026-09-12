import SwiftUI

/// 🔌 数据传输面板：USB 设备列表 + 速率徽章。
struct TransferPanelView: View {
    @ObservedObject var viewModel: MonitorViewModel

    var body: some View {
        SectionCard(title: "数据传输", systemImage: "arrow.triangle.swap") {
            let devices = viewModel.snapshot?.usbDevices ?? []
            if viewModel.snapshot == nil {
                EmptyHint(text: "等待首次快照…")
            } else if devices.isEmpty {
                EmptyHint(text: "未检测到 USB 设备（该接口可能未插设备）")
            } else {
                VStack(spacing: 8) {
                    ForEach(devices) { device in
                        HStack(spacing: 10) {
                            Image(systemName: "cable.connector")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(device.productName ?? "未知 USB 设备")
                                    .font(.callout.weight(.medium))
                                HStack(spacing: 6) {
                                    if let vendor = device.vendorName {
                                        Text(vendor)
                                    }
                                    if let bcdUSB = device.bcdUSB {
                                        Text("USB \(bcdUSB)")
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let speed = device.speed {
                                SpeedBadge(speed: speed)
                            }
                        }
                    }
                }
            }
        }
    }
}
