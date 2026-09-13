import CableKit
import SwiftUI

// MARK: - 通用小组件（全部使用语义色，深浅色模式均友好）

/// 分区卡片容器。`caption` 为标题旁的灰色说明文字（可选）。
struct SectionCard<Content: View>: View {
    private let title: String
    private let systemImage: String
    private let caption: String?
    private let content: Content

    init(title: String, systemImage: String, caption: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.caption = caption
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Label(title, systemImage: systemImage)
                    .font(.headline)
                if let caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// 充电状态徽章：正在充电（绿）/ 已接通电源（蓝）/ 未接通电源（灰）/ 等待数据。
/// "已接通电源"覆盖电池保温、优化充电暂停等 IsCharging=false 但插着电的状态。
struct ChargingBadge: View {
    let isCharging: Bool
    let isConnected: Bool
    let hasData: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var color: Color {
        guard hasData else { return .secondary }
        if isCharging { return .green }
        return isConnected ? .blue : .gray
    }

    private var text: String {
        if !hasData { return "等待数据" }
        if isCharging { return "正在充电" }
        return isConnected ? "已接通电源" : "未接通电源"
    }

    private var icon: String {
        if !hasData { return "hourglass" }
        if isCharging { return "bolt.fill" }
        return isConnected ? "powerplug.fill" : "bolt.slash"
    }

    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.14), in: Capsule())
            .accessibilityElement(children: .combine)
            // 充电中闪电脉冲（macOS 14+）：用动效传达"正在取电"的活跃状态；
            // 尊重系统的"减弱动态效果"（HIG 无障碍要求，symbolEffect 不会自动降级）。
            .symbolEffect(.pulse, options: .repeating, isActive: isCharging && !reduceMotion)
    }
}

/// 通用信息胶囊。
struct InfoChip: View {
    let text: String
    var systemImage: String? = nil
    var color: Color = .blue
    var isProminent: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(text)
        }
        .font(.caption)
        .fontWeight(isProminent ? .bold : .medium)
        .lineLimit(1)
        .monospacedDigit()
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(isProminent ? 0.22 : 0.14), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

/// USB 速率徽章："USB 3.x Gen2 · 10 Gbps"；40Gbps 及以上醒目高亮。
struct SpeedBadge: View {
    let speed: USBSpeed

    private var color: Color {
        switch speed.bitsPerSecond {
        case 40_000_000_000...: return .orange
        case 20_000_000_000..<40_000_000_000: return .purple
        case 10_000_000_000..<20_000_000_000: return .indigo
        case 5_000_000_000..<10_000_000_000: return .blue
        case 1_500_000..<5_000_000_000: return .teal
        default: return .gray
        }
    }

    private var isTopSpeed: Bool { speed.bitsPerSecond >= 40_000_000_000 }

    var body: some View {
        InfoChip(
            text: "\(speed.generation) · \(speed.label)",
            systemImage: isTopSpeed ? "bolt.fill" : nil,
            color: color,
            isProminent: isTopSpeed
        )
    }
}

/// 空状态提示。
struct EmptyHint: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "tray")
            Text(text)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}

/// 菜单面板里的整行按钮（带悬停高亮，接近原生菜单项）。
struct MenuRowButton: View {
    let title: String
    let systemImage: String
    /// 动作进行中（如"检查更新"轮询期间）图标脉冲提示；Reduce Motion 下静止。
    var isInProgress: Bool = false
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.callout)
                .symbolEffect(.pulse, options: .repeating, isActive: isInProgress && !reduceMotion)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 5)
                .padding(.horizontal, 8)
                .background(
                    isHovering ? Color.secondary.opacity(0.15) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// 按电量百分比挑选 SF Symbol。
enum BatteryGlyph {
    static func symbol(for percent: Double) -> String {
        switch percent {
        case 90...: return "battery.100"
        case 60..<90: return "battery.75"
        case 35..<60: return "battery.50"
        case 10..<35: return "battery.25"
        default: return "battery.0"
        }
    }
}
