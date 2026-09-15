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
            // 分三层而不是一整条 FlowLayout：headline 是结论（一句话头条），
            // "端口信息"是插拔元数据，"已启用传输"是能力枚举——混在一起挤成
            // 6、7 个胶囊时读不出主次，拆开后每一层自己内部再 flow 就够了。
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("端口状态")
                        .font(.subheadline.weight(.medium))
                    Spacer(minLength: 8)
                    Text(port.portID)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }

                if let headline = DiagnosticsEngine.portHeadline(port: port,
                                                                 power: viewModel.power(for: session)) {
                    InfoChip(text: headline, systemImage: "cable.connector", color: .blue, isProminent: true)
                }

                displaySection(of: session, fallbackPort: port)

                if port.plugOrientation != nil || port.connectionCount != nil {
                    portMetaRow(port)
                }

                if !port.transportsProvisioned.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("已启用传输")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        FlowLayout(spacing: 5) {
                            ForEach(port.transportsProvisioned, id: \.self) { transport in
                                InfoChip(text: Self.transportLabel(transport), color: .teal)
                            }
                        }
                    }
                }

                if port.eMarker != nil || port.partner?.vendorID != nil {
                    identitySection(port)
                }
                // 这根线自己对应端口的 PD 档位（与整机概览的"代表性"档位表是两回事：
                // 多线缆时每根线在这里各看各的协商档，不用切到概览去猜是哪根线在收电）。
                if let powerSource = port.powerSource, !powerSource.options.isEmpty {
                    PDOOptionsView(pdo: powerSource, sourceLabel: powerSource.sourceName)
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 该会话上跑的外接显示器：`IOPortTransportStateDisplayPort` 节点直接归属到物理端口
    /// （见 PortGrouping.displayPortLinks），不再是"检测到 DP 能力但定位不到是哪台屏幕"的
    /// 旧提示。分辨率/刷新率来自 EDID 身份匹配（PortGrouping.matchedDisplay）；匹配不唯一
    /// 时（如坞站带两台同型号显示器）只展示链路本身已知的信息，不瞎连到具体分辨率。
    @ViewBuilder
    private func displaySection(of session: CableSession, fallbackPort port: USBCPortSnapshot) -> some View {
        let links = viewModel.displayLinks(for: session)
        if !links.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("外接显示器")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                ForEach(links, id: \.link.id) { entry in
                    displayLinkRow(entry.link, display: entry.display)
                }
            }
        } else if port.transportsProvisioned.contains("DisplayPort") {
            // 端口报了 DP 能力，但没读到（或没解析出）对应的传输节点——比如节点刚建立还没
            // 采集到下一轮快照。如实降级为旧的粗粒度提示，而不是假装什么都没发生。
            HStack(spacing: 4) {
                Label("检测到视频信号（DisplayPort 交替模式已启用）", systemImage: "display")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.indigo)
                Image(systemName: "info.circle")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help("暂未读到该链路的显示器身份信息，稍后会自动补上")
            }
        }
    }

    private func displayLinkRow(_ link: DisplayPortLinkSnapshot, display: DisplaySnapshot?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "display")
                .font(.caption2)
                .foregroundStyle(.indigo)
            Text(Self.displayLinkName(link))
                .font(.caption2.weight(.medium))
            if let display {
                InfoChip(text: display.resolutionLabel, color: .indigo)
                if let hz = display.refreshRateHz {
                    InfoChip(text: "\(Int(hz.rounded())) Hz", color: .indigo)
                }
            } else {
                Text("分辨率暂不可用")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if let linkRate = link.linkRateDescription {
                InfoChip(text: linkRate, color: .teal)
            }
        }
    }

    /// 显示器名：优先厂商+型号（"AOC · U27U3XD"），缺失时退回通用文案，不编造。
    private static func displayLinkName(_ link: DisplayPortLinkSnapshot) -> String {
        switch (link.manufacturerName, link.productName) {
        case let (vendor?, name?): return "\(vendor) · \(name)"
        case (nil, let name?): return name
        case (let vendor?, nil): return vendor
        default: return "外接显示器"
        }
    }

    private func portMetaRow(_ port: USBCPortSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("端口信息")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            FlowLayout(spacing: 5) {
                if let orientation = port.plugOrientation {
                    InfoChip(text: orientation == 1 ? "正向插入" : "反向插入",
                             systemImage: "arrow.triangle.swap", color: .gray)
                }
                if let count = port.connectionCount {
                    InfoChip(text: "累计连接 \(count) 次", color: .gray)
                }
            }
        }
    }

    /// 线缆/对端身份：e-marker（SOP'）+ 对端设备（SOP）合成一个分组，用 chips
    /// 代替原来两三行逗号拼接的长句——"USB 3.2 Gen2(10Gbps)·5A(≤100W)·厂商ID未上报"
    /// 这种句子读起来是一整坨，拆成独立 chip 才能一眼扫到每个字段。
    /// 可信度提示（红线要求，谨慎措辞、不做真伪判决）保留成单独一行，用 ⓘ 图标
    /// 区分它是"警示性说明"而不是又一个身份事实。
    @ViewBuilder
    private func identitySection(_ port: USBCPortSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("线缆 / 对端身份")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            if let eMarker = port.eMarker {
                eMarkerChips(eMarker)
            } else {
                Text("线缆（e-marker）未上报身份信息")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if let partner = port.partner, let vendorID = partner.vendorID {
                // 对端厂商名（M3）：查内置 VID 库成功显示 "Realtek (0x0BDA)"，查不到时维持 hex。
                InfoChip(text: "对端 VID \(Self.partnerVIDLabel(vendorID))",
                         systemImage: "person.crop.circle", color: .gray)
            }
        }
    }

    /// e-marker 明细 chips：速度档 / 电流评级 / VID（未上报时如实说明）+ 可信度提示行。
    private func eMarkerChips(_ eMarker: EMarkerSnapshot) -> some View {
        let trustLine = EMarkerTrust.assess(eMarker).map(\.summary).joined(separator: "；")
        return VStack(alignment: .leading, spacing: 4) {
            FlowLayout(spacing: 5) {
                if let speed = eMarker.decodedSpeed {
                    InfoChip(text: speed.label, color: .purple)
                }
                if let rating = eMarker.decodedCurrentRating, rating != .reserved {
                    InfoChip(text: rating.label, color: .orange)
                }
                if let vendorID = eMarker.vendorID {
                    InfoChip(
                        text: vendorID == 0 ? "厂商 ID 未上报" : String(format: "e-marker 厂商 0x%04X", vendorID),
                        color: .gray
                    )
                }
            }
            if !trustLine.isEmpty {
                Label(trustLine, systemImage: "info.circle")
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
            // Grid 而不是各行独立的 HStack+Spacer：depth 缩进加在左边那格里，
            // 缩进多深都不影响右边速率徽章的列位置——之前每行是独立 HStack，
            // 徽章离名字文字只隔固定间距，名字长短一变徽章跟着左右挪，看着没对齐。
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                ForEach(devices) { device in
                    usbDeviceRow(device)
                }
            }
        }
    }

    private func usbDeviceRow(_ device: USBDeviceSnapshot) -> some View {
        let depth = PortGrouping.hubDepth(forLocationID: device.locationID)
        return GridRow {
            HStack(spacing: 8) {
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
            }
            .padding(.leading, CGFloat(depth) * 18)
            .accessibilityElement(children: .combine)
            .gridColumnAlignment(.leading)

            Group {
                if let speed = device.speed {
                    SpeedBadge(speed: speed)
                } else {
                    InfoChip(text: "速率未知", color: .gray)
                }
            }
            .gridColumnAlignment(.trailing)
        }
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
                // 拓扑深度缩进（M6）：与 USB 设备链的 hubDepth 缩进同一视觉模式。
                .padding(.leading, CGFloat(device.depth ?? 0) * 18)
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
