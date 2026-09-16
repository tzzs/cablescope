import SwiftUI

/// CableScope 入口：菜单栏常驻（MenuBarExtra）+ 主窗口详情。
@main
struct CableScopeApp: App {
    @StateObject private var viewModel: MonitorViewModel
    @AppStorage(AppPreferences.languageKey) private var language: AppPreferences.Language = .system
    @AppStorage(AppPreferences.themeKey) private var theme: AppPreferences.Theme = .system

    init() {
        // 新增偏好键必须先注册默认值，不能依赖 UserDefaults.bool(forKey:) 对未设置 key
        // 隐式返回 false 的行为——插拔通知历史上是"无条件开"，不注册会让老用户升级后
        // 静默变成关闭插拔通知。必须在下面任何读取偏好设置的代码之前调用。
        UserDefaults.standard.register(defaults: AppPreferences.registrationDefaults)

        // 菜单栏常驻形态：默认不占 Dock、不带前台激活（从 SwiftPM 可执行文件运行时必要）。
        // "在 Dock 显示图标"偏好（AppPreferences.showDockIconKey）持久化在 UserDefaults；
        // Info.plist 的 LSUIElement=true 只决定启动时的初始策略，运行期仍可用
        // setActivationPolicy 切到 .regular 加出 Dock 图标（同 Bartender/iStat Menus 的做法）。
        NSApplication.shared.setActivationPolicy(AppPreferences.showDockIcon ? .regular : .accessory)

        // 插拔通知：前台也弹横幅（无 bundle 的 SPM 运行会自动跳过）。
        NotificationController.activate()

        let viewModel = MonitorViewModel()
        _viewModel = StateObject(wrappedValue: viewModel)

        // 启动即开始监控，不依赖用户先点开菜单；start() 幂等。
        Task { @MainActor [weak viewModel] in
            viewModel?.start()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanelView(viewModel: viewModel)
                .appEnvironment(language: language, theme: theme)
        } label: {
            MenuBarLabelView(viewModel: viewModel, opensMainOnLaunch: true)
        }
        .menuBarExtraStyle(.window)

        // .accessory 策略下 SwiftUI 不会自动呈现 WindowGroup 窗口（启动时只有状态项窗口）；
        // 由 MenuBarLabelView 出现时通过 openWindow 拉起主窗口。
        mainWindow

        // IOKit 属性检查器：按类名浏览 IORegistry 全量属性（调试/高级用途）。
        Window("IOKit 属性检查器", id: "registry") {
            RegistryInspectorView()
                .appEnvironment(language: language, theme: theme)
        }
        .windowResizability(.contentMinSize)

        // 偏好设置：语言/主题/通知/Dock 图标。accessory 策略下没有标准菜单栏，
        // Cmd+, 不会自动生效，入口在 MenuBarPanelView 的菜单行列表里显式调用 openSettings()。
        Settings {
            SettingsView()
                .appEnvironment(language: language, theme: theme)
        }
    }

    private var mainWindow: some Scene {
        // Window（非 WindowGroup）：主窗口没有关联的文档/数据值，不需要 WindowGroup
        // 那种"同一 id 可以开多个实例"的语义——否则每次从菜单栏面板点"打开 CableScope"
        // 都会新开一个窗口。IOKit 属性检查器窗口同理，已经是 Window。
        Window("CableScope", id: "main") {
            MainWindowView(viewModel: viewModel)
                // idealHeight 显式给出：内容区是 ScrollView，不给的话 SwiftUI 会把
                // 空白的滚动容器当成"自然高度"塌成 minHeight，首次打开只看得到概览卡。
                // 760 大致能容下概览 + 线缆卡片行 + 一张详情卡，多数内容首屏可见。
                .frame(minWidth: 460, idealWidth: 520, minHeight: 440, idealHeight: 760)
                .appEnvironment(language: language, theme: theme)
        }
        .windowResizability(.contentMinSize)
    }
}
