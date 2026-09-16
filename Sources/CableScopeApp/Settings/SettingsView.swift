import SwiftUI

/// 设置页：通用（Dock 图标）/ 外观（主题）/ 语言 / 通知（总开关 + 细分开关）四个 tab。
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("通用", systemImage: "gearshape") }
            AppearanceSettingsTab()
                .tabItem { Label("外观", systemImage: "paintbrush") }
            LanguageSettingsTab()
                .tabItem { Label("语言", systemImage: "globe") }
            NotificationSettingsTab()
                .tabItem { Label("通知", systemImage: "bell") }
        }
        .frame(width: 420, height: 280)
    }
}

private struct GeneralSettingsTab: View {
    // 同一个 UserDefaults key，与 MenuBarPanelView 里的"在 Dock 显示图标"行天然同步——
    // 一个是随手切换的快捷入口，一个是正式收纳位，不是重复逻辑。
    @AppStorage(AppPreferences.showDockIconKey) private var showDockIcon = false

    var body: some View {
        Form {
            Toggle("在 Dock 显示图标", isOn: $showDockIcon)
                .onChange(of: showDockIcon) { _, newValue in
                    NSApplication.shared.setActivationPolicy(newValue ? .regular : .accessory)
                }
        }
        .padding(20)
    }
}

private struct AppearanceSettingsTab: View {
    @AppStorage(AppPreferences.themeKey) private var theme: AppPreferences.Theme = .system

    var body: some View {
        Form {
            Picker("外观", selection: $theme) {
                Text("跟随系统").tag(AppPreferences.Theme.system)
                Text("浅色").tag(AppPreferences.Theme.light)
                Text("深色").tag(AppPreferences.Theme.dark)
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        .padding(20)
    }
}

private struct LanguageSettingsTab: View {
    @AppStorage(AppPreferences.languageKey) private var language: AppPreferences.Language = .system

    var body: some View {
        Form {
            Picker("语言", selection: $language) {
                Text("跟随系统").tag(AppPreferences.Language.system)
                Text("简体中文").tag(AppPreferences.Language.zhHans)
                Text("English").tag(AppPreferences.Language.english)
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Text("部分窗口标题栏文字可能需要重新打开窗口才会切换语言。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }
}

private struct NotificationSettingsTab: View {
    @AppStorage(AppPreferences.notificationsEnabledKey) private var notificationsEnabled = true

    var body: some View {
        Form {
            Toggle("启用通知", isOn: $notificationsEnabled)
            Section {
                ForEach(AppPreferences.NotificationKind.allCases) { kind in
                    NotificationKindToggleRow(kind: kind)
                }
            }
            .disabled(!notificationsEnabled)
        }
        .padding(20)
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
