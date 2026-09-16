import SwiftUI

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

    var body: some View {
        Form {
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
        .frame(width: settingsWidth, height: 300)
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
