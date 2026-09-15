import Foundation

/// 一条 DisplayPort 传输链路状态（`IOPortTransportStateDisplayPort` 节点；真机验证：
/// 该节点仅在端口当前确有显示器接入、DP 交替模式生效时才存在，没有"空闲占位"）。
///
/// 这是目前唯一能把外接显示器**直接**归属到具体物理端口的数据源：节点自带
/// `TransportDescription`（形如 "Port-USB-C@1/DisplayPort"），前半截就是端口控制器
/// 用的 `portID`（"Port-USB-C@1"），与 `USBCPortSnapshot.portID` / `CableSession.physicalPortID`
/// 同一套命名——不需要像端口能力位那样"猜恰好一个口在跑 DP"。
/// 节点上还带着这台显示器自己的 EDID 身份（厂商/型号/序列号），用于跟 CoreGraphics 的
/// `CGDirectDisplayID`（`DisplaySnapshot`）精确配对，取到分辨率/刷新率——见
/// `PortGrouping.matchedDisplay`。
public struct DisplayPortLinkSnapshot: Codable, Hashable, Sendable, Identifiable {
    /// 归属的物理端口 portID（"Port-USB-C@1"）；节点形状不是 "Port-*/DisplayPort"
    /// 时为 nil（如原生 HDMI 口没有对应的 AppleHPM 端口），不强行归属。
    public let portID: String?
    /// 链路当前是否活跃（Active）
    public let isActive: Bool
    /// 是否经雷雳隧道传输（Tunneled）
    public let isTunneled: Bool
    /// 链路速率描述，IOKit 直读（如 "8.1 Gbps (HBR3)"）——比 system_profiler 尽力而为
    /// 解析出的 `DisplaySnapshot.linkRateLabel` 更可靠（该节点本机验证恒有值）。
    public let linkRateDescription: String?
    public let manufacturerName: String?
    public let productName: String?
    /// EDID Product ID，用于匹配 `CGDisplayModelNumber`
    public let productID: UInt32?
    /// EDID 序列号，用于匹配 `CGDisplaySerialNumber`（两台同型号显示器的兜底判据）
    public let serialNumber: UInt32?

    public init(portID: String?,
                isActive: Bool,
                isTunneled: Bool,
                linkRateDescription: String?,
                manufacturerName: String?,
                productName: String?,
                productID: UInt32?,
                serialNumber: UInt32?) {
        self.portID = portID
        self.isActive = isActive
        self.isTunneled = isTunneled
        self.linkRateDescription = linkRateDescription
        self.manufacturerName = manufacturerName
        self.productName = productName
        self.productID = productID
        self.serialNumber = serialNumber
    }

    public var id: String { "\(portID ?? "?")-\(productID ?? 0)-\(serialNumber ?? 0)" }
}
