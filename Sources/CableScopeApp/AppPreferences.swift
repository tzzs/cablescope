import Foundation

/// App 侧轻量偏好设置（UserDefaults 持久化）。目前只有"在 Dock 显示图标"一项，
/// 单独拆出常量键避免散落在 CableScopeApp.swift 与 MenuBarPanelView.swift 两处硬编码字符串。
enum AppPreferences {
    static let showDockIconKey = "showDockIcon"

    /// 默认 false：保持菜单栏工具一贯的"只占状态栏"形态，用户可在菜单面板里手动打开。
    static var showDockIcon: Bool {
        UserDefaults.standard.bool(forKey: showDockIconKey)
    }
}
