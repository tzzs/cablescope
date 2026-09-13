import SwiftUI

/// CableScope 入口：菜单栏常驻（MenuBarExtra）+ 主窗口详情。
@main
struct CableScopeApp: App {
    @StateObject private var viewModel: MonitorViewModel

    init() {
        // 菜单栏常驻形态：不占 Dock、不带前台激活（从 SwiftPM 可执行文件运行时必要）。
        NSApplication.shared.setActivationPolicy(.accessory)

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
        } label: {
            MenuBarLabelView(viewModel: viewModel, opensMainOnLaunch: true)
        }
        .menuBarExtraStyle(.window)

        // .accessory 策略下 SwiftUI 不会自动呈现 WindowGroup 窗口（启动时只有状态项窗口）；
        // 由 MenuBarLabelView 出现时通过 openWindow 拉起主窗口。
        mainWindow
    }

    private var mainWindow: some Scene {
        WindowGroup("CableScope", id: "main") {
            MainWindowView(viewModel: viewModel)
                .frame(minWidth: 460, idealWidth: 520, minHeight: 440)
        }
        .windowResizability(.contentMinSize)
    }
}
