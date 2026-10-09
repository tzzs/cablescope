import Foundation
import ServiceManagement

/// "登录时启动"：`SMAppService.mainApp`（macOS 13+）的薄封装。
///
/// 状态以系统为准、不在 UserDefaults 里另存一份——用户随时可能在「系统设置 → 通用 →
/// 登录项」里直接关掉它，自存的布尔值会和真实状态漂移。设置页每次出现/App 重新激活时
/// 重新读 `state`。
///
/// SwiftPM 裸可执行（`swift run CableScopeApp`）没有 bundle ID，登录项无从注册，
/// 归为 `.unavailable` 并在设置页如实说明，而不是让开关点了没反应。
enum LaunchAtLogin {
    enum State: Equatable {
        case enabled
        case disabled
        /// 已注册，但用户还没在系统设置的登录项里放行。
        case requiresApproval
        /// 非打包运行，无法注册。
        case unavailable
    }

    static var state: State {
        guard Bundle.main.bundleIdentifier != nil else { return .unavailable }
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .disabled
        case .notFound: return .unavailable
        @unknown default: return .disabled
        }
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
