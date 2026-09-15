import SwiftUI

/// 菜单栏状态项 label：仅一个固定图标（不随充电状态切换、不显示功率文字）。
/// 独立 View + @ObservedObject，保证 VM 变化时状态项实时刷新。
struct MenuBarLabelView: View {
    @ObservedObject var viewModel: MonitorViewModel
    /// 启动时自动呈现主窗口（accessory 策略下 SwiftUI 不自动展示 WindowGroup）
    var opensMainOnLaunch: Bool = false

    @Environment(\.openWindow) private var openWindow
    @State private var hasOpenedMain = false

    var body: some View {
        Image(systemName: "cable.connector")
            .imageScale(.small)
            .task {
            guard opensMainOnLaunch, !hasOpenedMain else { return }
            hasOpenedMain = true
            // 等场景装配完成后再拉起主窗口
            try? await Task.sleep(nanoseconds: 300_000_000)
            openWindow(id: "main")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }
}

/// 菜单栏弹出面板（.window 样式）：功率大字、电量、线缆列表（多线每线一行）、打开主窗口、检查更新、退出。
struct MenuBarPanelView: View {
    @ObservedObject var viewModel: MonitorViewModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    // 检查更新：请求进行中防重复点击；结果显示为按钮下方的一行小字，几秒后自动清除
    @State private var isCheckingForUpdate = false
    @State private var updateStatusMessage: String?

    // "在 Dock 显示图标"：默认关闭（纯菜单栏工具形态）。开启时切到 .regular 策略，
    // Dock 出现图标 + 可从 Cmd-Tab / App Switcher 切换；关闭时切回 .accessory。
    @AppStorage(AppPreferences.showDockIconKey) private var showDockIcon = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("CableScope", systemImage: "cable.connector")
                    .font(.headline)
                Spacer()
                ChargingBadge(isCharging: viewModel.isCharging,
                              isConnected: viewModel.isExternalConnected,
                              hasData: viewModel.snapshot != nil)
            }

            // 当前功率大字：充电中显示实时功率；已接通但未充电（保温/优化充电暂停）显示
            // 接通状态与 PD 合同能力；完全未接通时才是"暂无充电数据"。
            VStack(alignment: .leading, spacing: 2) {
                if let watts = viewModel.displayWatts {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(watts, format: .number.precision(.fractionLength(1)))")
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Text("W")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    Text("当前充电功率")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if viewModel.isExternalConnected {
                    Text("已接通电源")
                        .font(.title3.weight(.medium))
                    if let contract = viewModel.snapshot?.power?.pdContract {
                        Text(String(format: "PD 合同 %.0fW · 暂未充电", contract.watts))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("未在充电")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("暂无充电数据")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text("当前充电功率")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // 电量 + 线缆列表
            VStack(alignment: .leading, spacing: 8) {
                if let percent = viewModel.snapshot?.power?.batteryPercent {
                    HStack(spacing: 8) {
                        Image(systemName: BatteryGlyph.symbol(for: percent))
                            .foregroundStyle(.secondary)
                        ProgressView(value: percent.clamped(to: 0...100) / 100)
                            .frame(width: 90)
                        Text("\(Int(percent.rounded()))%")
                            .font(.callout)
                            .monospacedDigit()
                    }
                    .accessibilityElement(children: .combine)
                }
                sessionRows
            }

            Divider()

            MenuRowButton(title: "打开 CableScope", systemImage: "macwindow") {
                openMainWindow(id: "main")
            }
            MenuRowButton(title: "IOKit 属性检查器", systemImage: "list.bullet.rectangle.portrait") {
                openMainWindow(id: "registry")
            }
            MenuRowButton(title: "检查更新", systemImage: "arrow.down.circle",
                          isInProgress: isCheckingForUpdate) {
                Task { await checkForUpdates() }
            }
            if let updateStatusMessage {
                Text(updateStatusMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
            }
            Toggle(isOn: $showDockIcon) {
                Label("在 Dock 显示图标", systemImage: "dock.rectangle")
                    .font(.callout)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(.horizontal, 8)
            .onChange(of: showDockIcon) { _, isOn in
                NSApplication.shared.setActivationPolicy(isOn ? .regular : .accessory)
            }
            MenuRowButton(title: "退出", systemImage: "power") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(12)
        .frame(width: 250, alignment: .leading)
        // Esc 关闭面板（HIG：临时面板应支持 Esc）。面板是非激活面板，不一定是
        // NSApp.keyWindow（试过 performClose(nil) 打到 nil/别的窗口上），用场景
        // 自带的 \.dismiss 关这个面板场景本身更可靠。
        .onExitCommand {
            dismiss()
        }
        .task { viewModel.start() }
    }

    // MARK: 打开窗口

    /// 从菜单面板跳去打开某个窗口：MenuBarExtra 的 `.window` 样式点按钮后面板不会
    /// 像原生 NSMenu 那样自动收起。面板本身是非激活面板（不会成为 keyWindow），
    /// `NSApp.keyWindow?.performClose(nil)` 拿到的是 nil、什么也关不掉——
    /// 得用 SwiftUI 场景自带的 `\.dismiss` 关闭这个面板场景本身。
    /// （主窗口本身改用单例的 `Window` scene 而非 `WindowGroup`，见 CableScopeApp：
    /// 这里就算重复点击也只会前台激活同一个窗口，不会开出多个实例。）
    @MainActor
    private func openMainWindow(id: String) {
        dismiss()
        openWindow(id: id)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    // MARK: 检查更新

    /// 后台拉取 GitHub 最新 Release，与当前版本比较：
    /// 有更新弹提示对话框（可前往下载页）；无更新 / 网络失败显示一行状态小字。
    @MainActor
    private func checkForUpdates() async {
        guard !isCheckingForUpdate else { return }
        isCheckingForUpdate = true
        defer { isCheckingForUpdate = false }

        updateStatusMessage = "正在检查更新…"
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

        do {
            guard let repo = URL(string: UpdateChecker.repositoryURL) else {
                updateStatusMessage = "网络失败，请稍后再试"
                return
            }
            // URLSession async 请求在后台执行，不阻塞菜单栏 UI
            let latest = try await UpdateChecker.latestReleaseTag(for: repo)
            if UpdateChecker.isUpdateAvailable(current: current, latest: latest) {
                updateStatusMessage = nil
                UpdateChecker.presentUpdateDialog(current: current, latest: latest)
            } else {
                showTransientStatus("已是最新")
            }
        } catch {
            showTransientStatus("网络失败，请稍后再试")
        }
    }

    /// 显示一行状态小字，几秒后自动清除（期间被新消息替换则不清除）。
    @MainActor
    private func showTransientStatus(_ message: String) {
        updateStatusMessage = message
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if updateStatusMessage == message { updateStatusMessage = nil }
        }
    }

    // MARK: 线缆行

    /// 单线保持旧的"USB 速率"一行；多线时每线一行（≤3 行），更多则显示计数行引导打开主窗口。
    @ViewBuilder
    private var sessionRows: some View {
        let sessions = viewModel.sessions
        if sessions.count > 1 {
            Text("已连接线缆 (\(sessions.count))")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(sessions.prefix(3)) { session in
                HStack {
                    Text(session.shortPortLabel)
                        .font(.caption)
                    Spacer()
                    if let speed = session.topUSBSpeed {
                        SpeedBadge(speed: speed)
                    } else if session.deviceCount > 0 {
                        Text("\(session.deviceCount) 台设备")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("无设备")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if sessions.count > 3 {
                Text("其余 \(sessions.count - 3) 根 · 打开主窗口查看")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else {
            HStack(spacing: 6) {
                Text("USB")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let speed = viewModel.topUSBSpeed {
                    SpeedBadge(speed: speed)
                } else {
                    Text("无设备")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
