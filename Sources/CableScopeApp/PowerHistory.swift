import Foundation

/// 最近 5 分钟的功率采样（1Hz × 300 点环形缓冲），独立于 `MonitorViewModel` 的观察对象。
///
/// 为什么拆出来：它每秒变一次。放在 `MonitorViewModel` 的 `@Published` 里时，每秒一次的
/// `objectWillChange` 会让所有观察 VM 的视图——概览、线缆卡片、详情、菜单栏图标——整树
/// 重新求值，而真正用到它的只有一小块曲线。拆开后只有 `PowerHistorySection` 观察它。
@MainActor
final class PowerHistory: ObservableObject {
    /// 采样点。watts 为 NaN 表示当时无功率数据（折线在此断开）。
    struct Point: Identifiable, Equatable {
        let date: Date
        let watts: Double

        var id: Date { date }
        var isFinite: Bool { watts.isFinite }
    }

    static let capacity = 300 // 1Hz × 5 分钟

    @Published private(set) var points: [Point] = []

    func append(watts: Double, at date: Date = Date()) {
        points.append(Point(date: date, watts: watts))
        if points.count > Self.capacity {
            points.removeFirst(points.count - Self.capacity)
        }
    }

    /// 近 5 分钟是否出现过非零功率。未充电时采样全为 0，画出来是无意义的平线。
    var hasNonZeroPower: Bool {
        points.contains { $0.isFinite && $0.watts > 0.01 }
    }

    /// 曲线分段：NaN（无数据）断开后的连续段，段与段之间不连线。
    var segments: [[Point]] {
        var segments: [[Point]] = []
        var current: [Point] = []
        for point in points {
            if point.isFinite {
                current.append(point)
            } else if !current.isEmpty {
                segments.append(current)
                current = []
            }
        }
        if !current.isEmpty {
            segments.append(current)
        }
        return segments
    }
}
