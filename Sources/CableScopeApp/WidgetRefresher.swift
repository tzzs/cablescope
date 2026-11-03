import CableKit
import Foundation
import WidgetKit

/// 插拔 / 充电状态变化时让桌面小组件立即重新取数，而不是干等它自己的 15 分钟时间线。
///
/// 只在"小组件显示的内容可能变了"的事件上触发（插拔、开始/停止充电），评级/速率提升
/// 小组件根本不展示，不触发。WidgetKit 对重载次数有预算，再加一道最小间隔：窗口期内
/// 被吞掉的请求合并成窗口结束时的一次补发（trailing），保证最后一次状态变化一定会被刷到。
@MainActor
final class WidgetRefresher {
    static let widgetKind = "CableScopeChargingWidget"

    private let minimumInterval: TimeInterval
    private let bundleIdentifier: () -> String?
    private let reloadTimelines: () -> Void
    private var lastReload: Date?
    private var pendingReload: Task<Void, Never>?

    /// - Parameters:
    ///   - minimumInterval: 两次刷新之间的最小间隔；窗口期内被吞掉的请求合并成窗口
    ///     结束时的一次补发。
    ///   - bundleIdentifier: 是否有 bundle 的判据（SwiftPM 裸可执行没有 bundle，
    ///     也就没有可刷新的小组件）。注入以便单测。
    ///   - reloadTimelines: 真正的刷新动作。注入以便单测观察调用次数与时机。
    init(minimumInterval: TimeInterval = 15,
         bundleIdentifier: @escaping @MainActor () -> String? = { @MainActor in Bundle.main.bundleIdentifier },
         reloadTimelines: @escaping @MainActor () -> Void = { @MainActor in
             WidgetCenter.shared.reloadTimelines(ofKind: WidgetRefresher.widgetKind)
         }) {
        self.minimumInterval = minimumInterval
        self.bundleIdentifier = bundleIdentifier
        self.reloadTimelines = reloadTimelines
    }

    static func isRelevant(_ event: CableNotificationEvent) -> Bool {
        switch event {
        case .sessionConnected, .sessionDisconnected, .chargingStarted, .chargingStopped: return true
        case .usbSpeedUpgraded, .ratingUpgraded: return false
        }
    }

    func handle(_ events: [CableNotificationEvent]) {
        // SwiftPM 裸可执行没有 bundle，也就没有可刷新的小组件。
        guard bundleIdentifier() != nil, events.contains(where: Self.isRelevant) else { return }
        let now = Date()
        if let lastReload, now.timeIntervalSince(lastReload) < minimumInterval {
            guard pendingReload == nil else { return }
            let delay = minimumInterval - now.timeIntervalSince(lastReload)
            pendingReload = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                self?.pendingReload = nil
                self?.reload()
            }
            return
        }
        reload()
    }

    private func reload() {
        lastReload = Date()
        reloadTimelines()
    }
}
