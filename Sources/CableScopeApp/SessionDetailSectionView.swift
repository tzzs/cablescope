import CableKit
import SwiftUI

/// 选中线缆的详情区（方案 A 的"详情卡"）：
/// USB 设备链（按 hub 层级缩进）+ 雷雳设备 + 该端口历史评级 + 原始 IOKit 属性入口。
struct SessionDetailSectionView: View {
    @ObservedObject var viewModel: MonitorViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let session = viewModel.selectedSession {
            SectionCard(title: "详情 · \(session.portLabel)", systemImage: "cable.connector") {
                VStack(alignment: .leading, spacing: 12) {
                    portStatusRow(of: session)

                    if session.usbDevices.isEmpty, session.thunderboltDevices.isEmpty {
                        EmptyHint(text: "该端口当前没有设备")
                    }
                    if !session.usbDevices.isEmpty {
                        usbChain(session.usbDevices)
                    }
                    if !session.thunderboltDevices.isEmpty {
                        thunderboltList(session.thunderboltDevices)
                    }

                    Divider()
                    ratingRow(of: session)

                    HStack {
                        Spacer()
                        Button {
                            openWindow(id: "registry")
                            NSApplication.shared.activate(ignoringOtherApps: true)
                        } label: {
                            Label("查看原始 IOKit 属性", systemImage: "list.bullet.rectangle.portrait")
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    // MARK: 端口控制器状态（AppleHPM 直读；老机型/会话无配对时不显示）

    @ViewBuilder
    private func portStatusRow(of session: CableSession) -> some View {
        if let port = viewModel.port(for: session) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("端口状态")
                        .font(.subheadline.weight(.medium))
                    Spacer(minLength: 8)
                    Text(port.portID)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
                FlowLayout(spacing: 5) {
                    if let headline = DiagnosticsEngine.portHeadline(port: port,
                                                                     power: viewModel.power(for: session)) {
                        InfoChip(text: headline, systemImage: "cable.connector", color: .blue, isProminent: true)
                    }
                    if let orientation = port.plugOrientation {
                        InfoChip(text: orientation == 1 ? "正向插入" : "反向插入",
                                 systemImage: "arrow.triangle.swap", color: .gray)
                    }
                    if let count = port.connectionCount {
                        InfoChip(text: "累计连接 \(count) 次", color: .gray)
                    }
                    ForEach(port.transportsProvisioned, id: \.self) { transport in
                        InfoChip(text: Self.transportLabel(transport), color: .teal)
                    }
                }
                if let eMarker = port.eMarker {
                    eMarkerDetail(eMarker)
                }
                if let partner = port.partner, let vendorID = partner.vendorID {
                    // 对端厂商名（M3）：查内置 VID 库成功显示 "Realtek (0x0BDA)"，查不到时维持 hex。
                    Text("对端设备身份（SOP）· VID \(Self.partnerVIDLabel(vendorID))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// e-marker 明细行：速度档 / 电流评级 / VID（未上报时如实说明），
    /// 末尾追加 M3 可信度信号（零 VID / 未收录 VID / 保留评级，谨慎措辞）。
    private func eMarkerDetail(_ eMarker: EMarkerSnapshot) -> some View {
        var parts: [String] = []
        if let speed = eMarker.decodedSpeed {
            parts.append("线缆速率 \(speed.label)")
        }
        if let rating = eMarker.decodedCurrentRating, rating != .reserved {
            parts.append(rating.label)
        }
        if let vendorID = eMarker.vendorID {
            parts.append(String(format: vendorID == 0 ? "厂商 ID 未上报" : "e-marker 厂商 ID 0x%04X", vendorID))
        }
        let trustLine = EMarkerTrust.assess(eMarker).map(\.summary).joined(separator: "；")
        return VStack(alignment: .leading, spacing: 3) {
            if parts.isEmpty {
                Text("e-marker（SOP'）：线缆未上报身份信息")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Text("e-marker（SOP'）：\(parts.joined(separator: " · "))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if !trustLine.isEmpty {
                Text("可信度提示：\(trustLine)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    /// 对端 VID 的展示标签：目录命中返回 "Realtek (0x0BDA)"，未命中返回 "0x1234"。
    private static func partnerVIDLabel(_ vendorID: UInt32) -> String {
        let hex = String(format: "0x%04X", vendorID)
        guard let name = VendorDirectory.shared.name(forVendorID: vendorID) else { return hex }
        return "\(name) (\(hex))"
    }

    /// 传输能力缩写 → 中文标签。
    private static func transportLabel(_ raw: String) -> String {
        switch raw {
        case "CC": return "CC 通信"
        case "USB2": return "USB 2.0"
        case "USB3": return "USB 3.x"
        case "CIO": return "USB4/雷雳"
        case "DisplayPort": return "DisplayPort"
        default: return raw
        }
    }

    // MARK: USB 设备链（按 hub 层级缩进）

    private func usbChain(_ devices: [USBDeviceSnapshot]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("设备链（按 hub 层级缩进）")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(devices) { device in
                usbDeviceRow(device)
            }
        }
    }

    private func usbDeviceRow(_ device: USBDeviceSnapshot) -> some View {
        let depth = PortGrouping.hubDepth(forLocationID: device.locationID)
        return HStack(spacing: 8) {
            Image(systemName: Self.icon(for: device))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.displayName(device))
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(deviceSubtitle(device))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let speed = device.speed {
                SpeedBadge(speed: speed)
            } else {
                InfoChip(text: "速率未知", color: .gray)
            }
        }
        .padding(.leading, CGFloat(depth) * 18)
        .accessibilityElement(children: .combine)
    }

    private func deviceSubtitle(_ device: USBDeviceSnapshot) -> String {
        var parts: [String] = []
        if let vendor = device.vendorName { parts.append(vendor) }
        if let bcdUSB = device.bcdUSB { parts.append("USB \(bcdUSB)") }
        return parts.joined(separator: " · ")
    }

    // MARK: 雷雳设备

    private func thunderboltList(_ devices: [ThunderboltDeviceSnapshot]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("雷雳设备")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(devices) { device in
                HStack(spacing: 8) {
                    Image(systemName: "bolt.horizontal")
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    Text(device.name)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    if let vendorName = device.vendorName {
                        Text(vendorName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if let linkSpeedLabel = device.linkSpeedLabel {
                        InfoChip(text: linkSpeedLabel, systemImage: "link", color: .orange)
                    } else {
                        InfoChip(text: "链路未知", color: .gray)
                    }
                    // 雷雳代际（M3，ThunderboltDeviceSnapshot.generation）：有值时跟在链路速率 chip 后。
                    if let generation = device.generation {
                        InfoChip(text: generation, color: .purple)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    // MARK: 端口评级（胶囊样式，与整机评级一致）

    private func ratingRow(of session: CableSession) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let rating = viewModel.rating(forSessionID: session.id), rating.sampleCount > 0 {
                HStack(alignment: .firstTextBaseline) {
                    Text("端口评级")
                        .font(.subheadline.weight(.medium))
                    Spacer(minLength: 8)
                    Text("基于 \(rating.sampleCount) 次协商观测")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                FlowLayout(spacing: 5) {
                    InfoChip(
                        text: rating.summary,
                        color: rating.is5ACable ? .orange : .blue,
                        isProminent: rating.is5ACable
                    )
                }
                if let firstSeen = rating.firstSeen {
                    Text("首次观测 \(firstSeen.formatted(date: .abbreviated, time: .omitted)) · 历史峰值，拔线不清零")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("该端口暂无历史评级")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 产品名 → 厂商名 → "未知设备" 的展示回退链（与 CLI 的 displayName 逻辑一致）。
    private static func displayName(_ device: USBDeviceSnapshot) -> String {
        device.productName ?? device.vendorName ?? "未知设备"
    }

    /// 按产品名猜测设备图标（尽力而为，猜不中用线缆图标兜底）。
    private static func icon(for device: USBDeviceSnapshot) -> String {
        let name = (device.productName ?? "").lowercased()
        if name.contains("keyboard") || name.contains("键盘") { return "keyboard" }
        if name.contains("mouse") || name.contains("trackpad") { return "computermouse" }
        if name.contains("ssd") || name.contains("disk") || name.contains("drive")
            || name.contains("storage") || name.contains("硬盘") { return "externaldrive" }
        if name.contains("hub") || name.contains("坞") { return "arrow.triangle.branch" }
        if name.contains("display") || name.contains("monitor") || name.contains("显示器") { return "display" }
        return "cable.connector"
    }
}
