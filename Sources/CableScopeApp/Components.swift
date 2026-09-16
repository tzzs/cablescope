import CableKit
import SwiftUI

// MARK: - 通用小组件（全部使用语义色，深浅色模式均友好）

/// 分区卡片容器。`caption` 为标题旁的灰色说明文字（可选）。
struct SectionCard<Content: View>: View {
    private let title: LocalizedStringKey
    private let systemImage: String
    private let caption: LocalizedStringKey?
    private let content: Content

    init(title: LocalizedStringKey, systemImage: String, caption: LocalizedStringKey? = nil,
         @ViewBuilder content: () -> Content) {
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

/// 充电状态的语义（颜色 / 文案 / 图标），供下面胶囊徽章和工具栏纯图标两种样式共享，
/// 避免两处各写一份判断逻辑、后续改状态文案漏改一处。
private struct ChargingStatus {
    let color: Color
    let text: LocalizedStringKey
    let icon: String
    let isCharging: Bool

    init(isCharging: Bool, isConnected: Bool, hasData: Bool) {
        self.isCharging = isCharging
        switch (hasData, isCharging, isConnected) {
        case (false, _, _):
            color = .secondary; text = "等待数据"; icon = "hourglass"
        case (true, true, _):
            color = .green; text = "正在充电"; icon = "bolt.fill"
        case (true, false, true):
            // "已接通电源"覆盖电池保温、优化充电暂停等 IsCharging=false 但插着电的状态。
            color = .blue; text = "已接通电源"; icon = "powerplug.fill"
        case (true, false, false):
            color = .gray; text = "未接通电源"; icon = "bolt.slash"
        }
    }
}

/// 充电状态徽章：胶囊样式，文字+图标一起展示，用于菜单栏面板等有余量展示文案的场景。
struct ChargingBadge: View {
    let isCharging: Bool
    let isConnected: Bool
    let hasData: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let status = ChargingStatus(isCharging: isCharging, isConnected: isConnected, hasData: hasData)
        Label(status.text, systemImage: status.icon)
            .font(.caption.weight(.medium))
            .foregroundStyle(status.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(status.color.opacity(0.14), in: Capsule())
            .accessibilityElement(children: .combine)
            // 充电中闪电脉冲（macOS 14+）：用动效传达"正在取电"的活跃状态；
            // 尊重系统的"减弱动态效果"（HIG 无障碍要求，symbolEffect 不会自动降级）。
            .symbolEffect(.pulse, options: .repeating, isActive: status.isCharging && !reduceMotion)
    }
}

/// 充电状态的纯图标版本：用于主窗口工具栏，与"刷新""IOKit 属性"两个操作按钮同尺寸的
/// 图标并排展示。不用 Button 包裹（不可点击、不带悬停高亮），完整文案挪到 .help 提示里——
/// 这样它在工具栏里读作"一个状态指示图标"而不是"第三个大小、行为都不一样的按钮"。
struct ChargingStatusIcon: View {
    let isCharging: Bool
    let isConnected: Bool
    let hasData: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let status = ChargingStatus(isCharging: isCharging, isConnected: isConnected, hasData: hasData)
        Image(systemName: status.icon)
            .foregroundStyle(status.color)
            .symbolEffect(.pulse, options: .repeating, isActive: status.isCharging && !reduceMotion)
            .help(status.text)
            .accessibilityLabel(status.text)
    }
}

/// 通用信息胶囊。
///
/// 两个初始化器故意用**不同的参数标签**区分，而不是靠 Swift 重载消歧猜字面量/变量：
/// `text:`（`LocalizedStringKey`，字面量走 App 字符串目录查表）vs `verbatim:`（`String`，
/// 运行期动态拼出、已经按当前语言生成好的内容——如 CableKit 的 `rating.summary(locale:)`、
/// 设备型号名——原样展示，不二次查表）。
///
/// **踩过的坑**：最初仿照 `Text(_:)` 写成两个同名 `text:` 重载（`LocalizedStringKey` +
/// 泛型 `<S: StringProtocol>`），指望 Swift 像处理 `Text("字面量")` 那样自动优先选中
/// `LocalizedStringKey`。实测（真机截图对比）发现完全不生效——所有字面量调用都静默走了
/// `StringProtocol`/verbatim 分支，导致对应文案在切换语言后纹丝不动。`Text` 自己能这样
/// 消歧，不代表自定义类型的多参数、带默认值的初始化器也能——不能指望这条捷径，
/// 显式标签是唯一可靠的写法。
struct InfoChip: View {
    private let text: Text
    var systemImage: String? = nil
    var color: Color = .blue
    var isProminent: Bool = false

    init(text: LocalizedStringKey, systemImage: String? = nil, color: Color = .blue, isProminent: Bool = false) {
        self.text = Text(text)
        self.systemImage = systemImage
        self.color = color
        self.isProminent = isProminent
    }

    init(verbatim text: String, systemImage: String? = nil, color: Color = .blue, isProminent: Bool = false) {
        self.text = Text(text)
        self.systemImage = systemImage
        self.color = color
        self.isProminent = isProminent
    }

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            text
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

/// 空状态提示（同 `InfoChip`：字面量走 `LocalizedStringKey` 查表，运行期动态文案走
/// `String` verbatim）。
struct EmptyHint: View {
    private let text: Text

    init(text: LocalizedStringKey) { self.text = Text(text) }
    init(verbatim text: String) { self.text = Text(text) }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "tray")
            text
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
    let title: LocalizedStringKey
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
