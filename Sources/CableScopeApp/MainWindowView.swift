import SwiftUI

/// 主窗口（方案 A）：整机概览卡 + 线缆卡片行 + 选中线详情卡。
/// 电池 / 输入功率 / 显示器属于整机区；每根线缆一张卡片，点选后下方展示该线详情。
/// 窗口标题固定为 "CableScope"（Window scene 声明处），正文不再重复渲染同名大标题；
/// 快照时间戳改用 `.navigationSubtitle` 挂在系统标题栏下方，高频操作（刷新 / IOKit
/// 属性 / 设置）都提到 `.toolbar` 里——工具栏由 AppKit 承载，不随内容 ScrollView
/// 一起滚动，滚到详情区也不用先滚回顶部才能点刷新。充电状态不放进工具栏：它不是
/// 操作、不可点击，跟两个真按钮摆一起会显得"多出来一个不一样的东西"，而且
/// System Overview 卡片本身就是打开窗口最先看到的内容，工具栏里再放一份是重复。
struct MainWindowView: View {
    @ObservedObject var viewModel: MonitorViewModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                OverviewSectionView(viewModel: viewModel)
                CableCardsSectionView(viewModel: viewModel)
                SessionDetailSectionView(viewModel: viewModel)
                ThroughputSectionView()
            }
            .padding(16)
        }
        .task { viewModel.start() }
        .navigationSubtitle(subtitleText)
        .toolbar {
            // 统一放进同一个 .primaryAction 组、同尺寸纯图标按钮：三个都是可点击的
            // 操作，行为和视觉权重一致，不掺一个不可点的状态指示。
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    openWindow(id: "registry")
                    NSApplication.shared.activate(ignoringOtherApps: true)
                } label: {
                    Label("IOKit 属性", systemImage: "list.bullet.rectangle.portrait")
                }
                .keyboardShortcut("i", modifiers: .command)

                Button {
                    viewModel.refresh()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                        // 采集中图标脉冲替代独立进度圈（.rotate 需 macOS 15，取 14 可用的 pulse）；
                        // Reduce Motion 下静止。
                        .symbolEffect(.pulse, options: .repeating,
                                      isActive: viewModel.isRefreshing && !reduceMotion)
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(viewModel.isRefreshing)

                // 设置入口：保留独立 Settings 窗口（四个 tab 不变，符合 macOS 原生 App
                // 一贯把 Settings 做成独立小窗口的做法），只是把入口从"只能从状态栏菜单
                // 找"挪到主窗口工具栏里，跟刷新/IOKit 属性平级，不用先绕去菜单栏才能找到。
                Button {
                    openSettings()
                } label: {
                    Label("设置", systemImage: "gearshape")
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }

    private var subtitleText: String {
        if let timestamp = viewModel.snapshot?.timestamp {
            return "最近快照 \(timestamp.formatted(date: .omitted, time: .standard))"
        }
        return "等待首次快照…"
    }
}
