import CableKit
import SwiftUI

/// 已连接线缆区（方案 A 的"卡片行"）：每个物理端口一张可选卡片，
/// 点选后下方详情区展示该线的设备链与端口评级。
struct CableCardsSectionView: View {
    @ObservedObject var viewModel: MonitorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(headerTitle)
                .font(.headline)

            if viewModel.sessions.isEmpty {
                EmptyHint(text: "未检测到线缆 / 设备")
                    .padding(.vertical, 8)
            } else {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(viewModel.sessions) { session in
                        CableCardView(
                            session: session,
                            isSelected: session.id == viewModel.selectedSession?.id,
                            rating: viewModel.rating(forSessionID: session.id),
                            power: viewModel.power(for: session),
                            port: viewModel.port(for: session)
                        ) {
                            viewModel.selectSession(session.id)
                        }
                    }
                }
                .focusable()
                // 键盘可达性（HIG）：获得焦点后 ←/→/↑/↓ 在卡片间移动选中。
                .onMoveCommand { movement in
                    switch movement {
                    case .right, .down: viewModel.selectAdjacentSession(offset: 1)
                    case .left, .up: viewModel.selectAdjacentSession(offset: -1)
                    @unknown default: break
                    }
                }
                // 卡片自带 accent 选中描边，足以指示位置；抑制系统焦点环，
                // 避免启动时初始焦点在选中描边外再叠一圈蓝色光晕。
                .focusEffectDisabled()
            }
        }
    }

    /// 列宽策略（与样机一致）：1 张卡撑满整行、2 张对半分，≥3 张再走自适应网格。
    private var columns: [GridItem] {
        let count = viewModel.sessions.count
        if count <= 2 {
            return Array(repeating: GridItem(.flexible(), spacing: 10), count: max(count, 1))
        }
        return [GridItem(.adaptive(minimum: 220), spacing: 10)]
    }

    private var headerTitle: LocalizedStringKey {
        viewModel.sessions.isEmpty ? "已连接线缆" : "已连接线缆 (\(viewModel.sessions.count))"
    }
}

/// 单根线缆卡片：端口名 + 状态点 + 能力 chips + 端口历史评级摘要。
/// `power` 仅在整机电源可无歧义归属到本线时传入（归属规则见 PortGrouping）；
/// 多线时充电/合同只在整机概览出现，但端口直读的 PD 合同仍会以胶囊提示。
/// `port` 是端口控制器直读数据（AppleHPM），携带 e-marker / 端口形态；老机型为 nil。
struct CableCardView: View {
    let session: CableSession
    let isSelected: Bool
    let rating: CableRating?
    let power: PowerSnapshot?
    var port: USBCPortSnapshot? = nil
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.locale) private var locale

    private var statusColor: Color {
        if let power, power.isCharging { return .green }
        if port?.powerSource?.winning != nil || session.deviceCount > 0 { return .blue }
        return .gray
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true) // 状态语义由 chips 文本承载，纯颜色点对 VoiceOver 无意义
                    Text(session.portLabel)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }

                FlowLayout(spacing: 5) {
                    if let power {
                        if power.isCharging, let watts = power.watts, watts > 0 {
                            InfoChip(
                                text: "⚡ \(watts, format: .number.precision(.fractionLength(1)))W 充电中",
                                systemImage: "bolt.fill",
                                color: .orange,
                                isProminent: true
                            )
                        } else if power.externalConnected {
                            InfoChip(text: "已接通电源", systemImage: "powerplug.fill", color: .blue)
                        }
                    } else if let winning = port?.powerSource?.winning {
                        // 整机电源不可归属到本线（多端口同时有合同等），端口直读的
                        // 协商合同仍能说明"这根线在收电"。
                        InfoChip(text: "PD 合同 \(Int(winning.watts.rounded()))W",
                                 systemImage: "bolt.fill", color: .blue)
                    }
                    if let speed = session.topUSBSpeed {
                        SpeedBadge(speed: speed)
                    }
                    if let eMarker = port?.eMarker {
                        eMarkerChips(eMarker)
                    }
                    if rating?.is5ACable == true, port?.eMarker == nil {
                        // 有直读 e-marker 时上面已给出更准确的档位；仅在无直读数据时展示历史推断。
                        InfoChip(text: "5A e-marker", systemImage: "checkmark.seal.fill", color: .orange)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(deviceSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let rating, rating.sampleCount > 0 {
                        Text(rating.summary(locale: locale))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    } else {
                        Text("暂无评级")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? Color.accentColor.opacity(0.10)
                                     : (isHovering ? Color.secondary.opacity(0.14) : Color.secondary.opacity(0.08)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            .focusEffectDisabled() // 选中描边即焦点指示，抑制 Full Keyboard Access 下的按钮焦点环
        }
        .buttonStyle(.plain)
        // 每张卡的 Button 本身也是可获得键盘焦点的目标——跟外层 LazyVGrid 的
        // .focusable() 叠在一起，就是两层各画一圈环：容器一圈、button 自己再一圈。
        // 键盘导航（方向键切换选中）已经由外层 onMoveCommand 接管，这里的 Button
        // 不需要自己再抢一次焦点，点击 action 不受影响。
        .focusable(false)
        .onHover { isHovering = $0 }
    }

    private var deviceSummary: LocalizedStringKey {
        guard session.deviceCount > 0 else {
            return port?.powerSource?.winning != nil ? "纯充电连接 · 无数据设备" : "端口无设备"
        }
        switch session.kind {
        case .usb: return "\(session.usbDevices.count) 台 USB 设备"
        case .thunderbolt: return "\(session.thunderboltDevices.count) 台雷雳设备"
        }
    }

    /// 直读 e-marker 的胶囊：产品类型（被动/主动线缆）+ 电流评级；
    /// 可信度信号按 EMarkerTrust.assess 渲染（零 VID/未收录 VID 灰色、保留评级橙色），
    /// 取代旧的"e-marker 未上报厂商"硬编码 chip，天然去重。
    @ViewBuilder
    private func eMarkerChips(_ eMarker: EMarkerSnapshot) -> some View {
        let trustNotes = EMarkerTrust.assess(eMarker)
        if let description = eMarker.productTypeDescription {
            InfoChip(
                verbatim: DiagnosticsEngine.eMarkerDescription(description, locale: locale),
                systemImage: "cable.connector",
                color: .indigo
            )
        }
        if let rating = eMarker.decodedCurrentRating, rating != .reserved {
            InfoChip(verbatim: rating.label, systemImage: "checkmark.seal.fill", color: .orange)
        }
        ForEach(trustNotes, id: \.self) { note in
            switch note {
            case .zeroVendorID:
                InfoChip(text: "e-marker 未上报厂商", systemImage: "questionmark.circle", color: .gray)
            case .reservedCurrentRating:
                InfoChip(verbatim: note.summary(locale: locale), systemImage: "questionmark.circle", color: .orange)
            case .unknownVendorID, .missingIdentity:
                InfoChip(verbatim: note.summary(locale: locale), systemImage: "questionmark.circle", color: .gray)
            }
        }
    }
}

/// 简单流式布局：chips 超出卡片宽度时自动换行（macOS 13 Layout 协议）。
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? x, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
