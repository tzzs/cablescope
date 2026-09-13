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

    // 检查更新：请求进行中防重复点击；结果显示为按钮下方的一行小字，几秒后自动清除
    @State private var isCheckingForUpdate = false
    @State private var updateStatusMessage: String?

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
                openWindow(id: "main")
                // accessory 形态下打开窗口后主动激活，避免窗口出现在后台。
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            MenuRowButton(title: "IOKit 属性检查器", systemImage: "list.bullet.rectangle.portrait") {
                openWindow(id: "registry")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            MenuRowButton(title: "检查更新", systemImage: "arrow.triangle.down.circle",
                          isInProgress: isCheckingForUpdate) {
                Task { await checkForUpdates() }
            }
            if let updateStatusMessage {
                Text(updateStatusMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
            }
            MenuRowButton(title: "退出", systemImage: "power") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(12)
        .frame(width: 250, alignment: .leading)
        // Esc 关闭面板（HIG：临时面板应支持 Esc）。MenuBarExtra .window 样式
        // 没有官方关闭 API（FB383/328 仍开放）；面板打开时即为 key window，
        // 直接对它 performClose 即可。
        .onExitCommand {
            NSApp.keyWindow?.performClose(nil)
        }
        .task { viewModel.start() }
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
