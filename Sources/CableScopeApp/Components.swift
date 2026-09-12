import CableKit
import SwiftUI

// MARK: - 通用小组件（全部使用语义色，深浅色模式均友好）

/// 分区卡片容器。
struct SectionCard<Content: View>: View {
    private let title: String
    private let systemImage: String
    private let content: Content

    init(title: String, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// 充电状态徽章：正在充电（绿）/ 未充电（灰）/ 等待数据。
struct ChargingBadge: View {
    let isCharging: Bool
    let hasData: Bool

    private var color: Color {
        guard hasData else { return .secondary }
        return isCharging ? .green : .gray
    }

    private var text: String {
        if !hasData { return "等待数据" }
        return isCharging ? "正在充电" : "未充电"
    }

    private var icon: String {
        if !hasData { return "hourglass" }
        return isCharging ? "bolt.fill" : "bolt.slash"
    }

    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.14), in: Capsule())
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

/// 标题 + 数值的小指标。
struct MetricLabel: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.medium))
                .monospacedDigit()
        }
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
    }
}

/// 菜单面板里的整行按钮（带悬停高亮，接近原生菜单项）。
struct MenuRowButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.callout)
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
