import Foundation

// MARK: - 服务协议（IOKit 适配层的契约，CLI/App 依赖协议而非实现，便于 mock 测试）

public protocol USBServiceProtocol: Sendable {
    /// 枚举当前所有 USB 设备（IOUSBHostDevice）
    func listUSBDevices() async throws -> [USBDeviceSnapshot]
}

public protocol PowerServiceProtocol: Sendable {
    /// 当前电源/充电状态（AppleSmartBattery + IOPowerSources）
    func currentPower() async throws -> PowerSnapshot?
}

public protocol DisplayServiceProtocol: Sendable {
    /// 在线显示器列表（CoreGraphics + system_profiler 尽力补链路信息）
    func listDisplays() async throws -> [DisplaySnapshot]
}

public protocol ThunderboltServiceProtocol: Sendable {
    /// 雷电设备列表（SPThunderboltDataType / IOThunderboltPort）
    func listThunderboltDevices() async throws -> [ThunderboltDeviceSnapshot]
}

/// 快照监视器：组合各 Service，提供单次快照与插拔事件流
public protocol CableMonitorProtocol: Sendable {
    /// 立即采集一次完整快照
    func snapshotNow() async throws -> CableSnapshot
    /// 快照事件流：启动时发一次，之后每次 USB 热插拔/电源变化发新快照
    func snapshotStream() -> AsyncStream<CableSnapshot>
}
