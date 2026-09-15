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

/// PD 档位表（档位胶囊 + 当前协商档高亮）：整机概览的"代表性"端口与线缆详情的
/// "这根线对应的端口"共用同一份渲染逻辑，避免两处各画一套还容易画歪。
struct PDOOptionsView: View {
    let pdo: PDOPortPowerSnapshot
    let sourceLabel: String

    /// `.adaptive` 而不是固定列数：卡片宽度随窗口/侧栏变化，列数跟着自动重排，
    /// 跟 CSS Grid 的 `auto-fill` 是一回事——档位少时自然铺不满最后一行，不强撑。
    private let columns = [GridItem(.adaptive(minimum: 108), spacing: 6)]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label("PD 档位（\(sourceLabel)）", systemImage: "list.number")
                    .font(.callout)
                Text("端口上报")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            // 网格胶囊（方案 B，跟用户对比三版方案后选定）：每档做成独立小块，
            // 铺成二维网格而不是单向 FlowLayout 排队——横向纵向都用得上卡片
            // 宽度，视觉语言也和"端口信息""已启用传输"两处的胶囊保持一致。
            LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                ForEach(pdo.options) { phase in
                    let isWinning = pdo.winningIndex == pdo.options.firstIndex(of: phase)
                    PDOGridChip(phase: phase, isWinning: isWinning)
                }
            }
            if pdo.winning == nil {
                Text("当前无协商档（未在取电）")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// PD 档位网格里的单个胶囊：上行 V/A（次要），下行功率数值（主要，协商档橙色高亮）。
private struct PDOGridChip: View {
    let phase: PDOPhase
    let isWinning: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(phase.voltAmpLabel)
                .font(.caption2)
                .foregroundStyle(isWinning ? Color.orange.opacity(0.85) : Color.secondary)
            HStack(spacing: 3) {
                if isWinning {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 9))
                }
                Text("\(Int(phase.watts.rounded()))W")
            }
            .font(.callout.weight(.semibold))
            .foregroundStyle(isWinning ? Color.orange : Color.primary)
        }
        .monospacedDigit()
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(isWinning ? Color.orange.opacity(0.16) : Color.secondary.opacity(0.1),
                    in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
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
/// 不带前置图标——原生 NSMenu 的纯文字项就是这个样式，同时也避免了不同 SF Symbol
/// 字形宽度不一导致的文字起点错位（Label 不保留固定宽度的图标列）。
/// 高亮背景仍然贴着面板的内容宽度铺满（`.frame(maxWidth: .infinity)` 在内部
/// 水平 padding 之后应用，背景尺寸不受影响），和分隔线上方的内容（"已连接线缆"、
/// 电量行等）保持同一条外边界；但文字/勾选标记相对这条外边界额外留了内边距，
/// 避免像早期版本那样文字直接贴着高亮矩形的左右边缘，没有呼吸空间。
struct MenuRowButton: View {
    let title: String
    /// 动作进行中（如"检查更新"轮询期间）在行尾显示小号进度指示。
    var isInProgress: Bool = false
    /// 当前是否为选中状态——贴近原生 NSMenu 里"可勾选菜单项"的做法（行尾一个
    /// checkmark），而不是在纯文字菜单里插一个 iOS/系统设置风格的开关控件。
    var isChecked: Bool = false
    let action: () -> Void

    @State private var isHovering = false

    private static let horizontalInset: CGFloat = 8

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.callout)
                Spacer(minLength: 8)
                if isInProgress {
                    ProgressView()
                        .controlSize(.small)
                } else if isChecked {
                    Image(systemName: "checkmark")
                        .font(.callout.weight(.semibold))
                }
            }
            .padding(.horizontal, Self.horizontalInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
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
