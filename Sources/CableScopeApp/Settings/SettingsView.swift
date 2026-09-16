import SwiftUI
import UserNotifications

/// 设置页：通用（Dock 图标）/ 外观（主题）/ 语言 / 通知（总开关 + 细分开关）四个 tab。
///
/// 每个 tab 的内容量差别很大（"通用"只有一个开关，"通知"有六行），按 HIG 对 macOS
/// 设置窗口的要求——"窗口应随当前 pane 的内容量调整尺寸，用户不用自己拉大窗口看更多
/// 内容"——**不）**给整个 TabView 套一个统一的大 frame，而是每个 tab 自己声明贴合内容的
/// 尺寸，配合 CableScopeApp.swift 里 `Settings` scene 的 `.windowResizability(.contentSize)`，
/// 切 tab 时窗口跟着重新收放，不会有大片空白。
struct SettingsView: View {
    // 记住上次停留的 tab（HIG："设置窗口应恢复最近查看的 pane"）；用 UserDefaults 持久化，
    // 比 HIG 最低要求（仅本次会话内记住）更进一步，跨次启动也保留。
    @AppStorage("settingsSelectedTab") private var selectedTab: SettingsTab = .general

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsTab()
                .tabItem { Label("通用", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            AppearanceSettingsTab()
                .tabItem { Label("外观", systemImage: "paintbrush") }
                .tag(SettingsTab.appearance)
            LanguageSettingsTab()
                .tabItem { Label("语言", systemImage: "globe") }
                .tag(SettingsTab.language)
            NotificationSettingsTab()
                .tabItem { Label("通知", systemImage: "bell") }
                .tag(SettingsTab.notifications)
        }
    }
}

private enum SettingsTab: String {
    case general, appearance, language, notifications
}

/// 统一宽度：原生设置窗口切 tab 时通常只有高度随内容变化，宽度保持稳定，
/// 避免每次切换 tab 窗口左右也跟着抖动。
private let settingsWidth: CGFloat = 360

private struct GeneralSettingsTab: View {
    // 同一个 UserDefaults key，与 MenuBarPanelView 里的"在 Dock 显示图标"行天然同步——
    // 一个是随手切换的快捷入口，一个是正式收纳位，不是重复逻辑。
    @AppStorage(AppPreferences.showDockIconKey) private var showDockIcon = false

    var body: some View {
        Form {
            Section {
                Toggle("在 Dock 显示图标", isOn: $showDockIcon)
                    .onChange(of: showDockIcon) { _, newValue in
                        NSApplication.shared.setActivationPolicy(newValue ? .regular : .accessory)
                    }
            }
        }
        .formStyle(.grouped)
        .frame(width: settingsWidth, height: 100)
    }
}

private struct AppearanceSettingsTab: View {
    @AppStorage(AppPreferences.themeKey) private var theme: AppPreferences.Theme = .system

    var body: some View {
        Form {
            Section {
                Picker("外观", selection: $theme) {
                    Text("跟随系统").tag(AppPreferences.Theme.system)
                    Text("浅色").tag(AppPreferences.Theme.light)
                    Text("深色").tag(AppPreferences.Theme.dark)
                }
                .pickerStyle(.segmented)
            }
        }
        .formStyle(.grouped)
        .frame(width: settingsWidth, height: 100)
    }
}

private struct LanguageSettingsTab: View {
    @AppStorage(AppPreferences.languageKey) private var language: AppPreferences.Language = .system

    var body: some View {
        Form {
            Section {
                Picker("语言", selection: $language) {
                    Text("跟随系统").tag(AppPreferences.Language.system)
                    Text("简体中文").tag(AppPreferences.Language.zhHans)
                    Text("English").tag(AppPreferences.Language.english)
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("部分窗口标题栏文字可能需要重新打开窗口才会切换语言。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: settingsWidth, height: 130)
    }
}

private struct NotificationSettingsTab: View {
    @AppStorage(AppPreferences.notificationsEnabledKey) private var notificationsEnabled = true
    // nil = 还没查到；查到之后如果不是 .authorized/.provisional，说明系统层面就没放行，
    // 这些开关全打开也不会真的弹出通知——这是"开了开关却没有通知"最常见的实际原因，
    // 之前完全没有暴露给用户，只能在系统设置里自己排查。
    @State private var authorizationStatus: UNAuthorizationStatus?

    private var needsAttention: Bool {
        guard let authorizationStatus else { return false }
        return authorizationStatus != .authorized && authorizationStatus != .provisional
    }

    var body: some View {
        Form {
            if !NotificationAvailability.isAvailable {
                // 未签名调试构建：压根不能碰 UNUserNotificationCenter（会直接崩进程，
                // 见 NotificationAvailability 的注释），这里只如实说明，不查、不请求授权。
                Section {
                    Label("此构建未正确签名，通知功能不可用（正式发布包不受影响）",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.orange)
                }
            } else if needsAttention {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("系统未授权通知，以下开关不会实际生效", systemImage: "exclamationmark.triangle.fill")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.orange)
                        Button("前往系统设置开启") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
            }
            Section {
                Toggle("启用通知", isOn: $notificationsEnabled)
            }
            Section {
                ForEach(AppPreferences.NotificationKind.allCases) { kind in
                    NotificationKindToggleRow(kind: kind)
                }
            }
            .disabled(!notificationsEnabled)
        }
        .formStyle(.grouped)
        .frame(width: settingsWidth, height: needsAttention || !NotificationAvailability.isAvailable ? 400 : 300)
        .task { await requestAuthorizationIfNeededAndRefresh() }
        // 用户点"前往系统设置开启"切过去之后，App 会失焦；等他们改完权限切回来、
        // App 重新变为活跃状态时顺手再查一遍——不然横幅会一直停在"未授权"的旧状态，
        // 得关掉设置窗口重开才会刷新，用户会以为自己没设置对。
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshAuthorizationStatus() }
        }
    }

    @MainActor
    private func requestAuthorizationIfNeededAndRefresh() async {
        guard NotificationAvailability.isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            // 用户主动点进"通知"设置页，本身就是请求权限最自然的时机（Apple 官方指引：
            // 在上下文里请求授权，比首次启动时自动请求体验更好）——不用等到第一条真实
            // 通知触发时才弹系统授权框，那时用户很可能根本没在看屏幕，容易错过，
            // 之后就一直停在"未决定"状态。
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
        await refreshAuthorizationStatus()
    }

    @MainActor
    private func refreshAuthorizationStatus() async {
        guard NotificationAvailability.isAvailable else { return }
        authorizationStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}

/// `ForEach` 里每个开关需要各自独立、编译期确定的 `@AppStorage` key，不能用动态 key，
/// 所以拆成这个小 View，在 `init` 里手动构造 `_isOn`。
private struct NotificationKindToggleRow: View {
    let kind: AppPreferences.NotificationKind
    @AppStorage private var isOn: Bool

    init(kind: AppPreferences.NotificationKind) {
        self.kind = kind
        self._isOn = AppStorage(wrappedValue: kind.defaultEnabled, kind.storageKey)
    }

    var body: some View {
        Toggle(kind.displayName, isOn: $isOn)
    }
}

private extension AppPreferences.NotificationKind {
    var displayName: LocalizedStringKey {
        switch self {
        case .plugUnplug: return "线缆插拔"
        case .chargingStarted: return "开始充电"
        case .chargingStopped: return "停止充电"
        case .speedUpgraded: return "协商速率提升"
        case .ratingUpgraded: return "线缆评级提升"
        }
    }
}
