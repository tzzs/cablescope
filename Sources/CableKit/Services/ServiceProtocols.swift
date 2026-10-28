import Foundation

// MARK: - 服务协议（IOKit 适配层的契约，CLI/App 依赖协议而非实现，便于 mock 测试）

public protocol USBServiceProtocol: Sendable {
    /// 枚举当前所有 USB 设备（IOUSBHostDevice）
    func listUSBDevices() async -> [USBDeviceSnapshot]
}

public protocol PowerServiceProtocol: Sendable {
    /// 当前电源/充电状态（AppleSmartBattery + IOPowerSources）
    func currentPower() async -> PowerSnapshot?
}

public protocol DisplayServiceProtocol: Sendable {
    /// 在线显示器列表 (CoreGraphics + system_profiler 尽力补链路信息)
    func listDisplays() async -> [DisplaySnapshot]
}

public protocol ThunderboltServiceProtocol: Sendable {
    /// 雷雳设备列表 (SPThunderboltDataType / IOThunderboltPort)
    func listThunderboltDevices() async -> [ThunderboltDeviceSnapshot]
}

public protocol PortControllerServiceProtocol: Sendable {
    /// USB-C / MagSafe 端口控制器状态 (AppleHPM/AppleTC + SOP/SOP' + PD 档位)
    func listPorts() async -> [USBCPortSnapshot]
}

public protocol DisplayPortTransportServiceProtocol: Sendable {
    /// DisplayPort 传输链路状态 (IOPortTransportStateDisplayPort；仅在有显示器接入时节点才存在)
    func listDisplayPortLinks() async -> [DisplayPortLinkSnapshot]
}

public protocol RegistryServiceProtocol: Sendable {
    /// 按任意 IOKit 类名枚举 IORegistry 条目，携带全量原始属性。
    ///
    /// 必须同时报出**结果是否完整**：条目数是否触顶被截断、有多少条目的属性读取失败。
    /// 诊断工具把不完整的结果说成"全部"，排查结论就建立在残缺数据上。
    func enumerate(matchingClass className: String) async -> RegistryEnumerationResult
}

extension RegistryServiceProtocol {
    /// 只要条目（调用方不关心完整性时用这个）。
    public func listEntries(matchingClass className: String) async -> [RegistryEntrySnapshot] {
        await enumerate(matchingClass: className).entries
    }
}

/// 快照监视器：组合各 Service，提供单次快照与插拔事件流
public protocol CableMonitorProtocol: Sendable {
    /// 立即采集一次完整快照
    func snapshotNow() async -> CableSnapshot
    /// 快照事件流：启动时发一次，之后每次 USB 热插拔/电源变化发新快照
    func snapshotStream() -> AsyncStream<CableSnapshot>
}
