import Foundation

/// 一根线缆 / 一个物理端口上聚合出的「线缆会话」。
///
/// 由 `PortGrouping` 从整机快照聚合而来：
/// - 端口会话：AppleHPM 活跃端口直接成卡（纯 PD 充电线不枚举设备，靠它才可见），
///   USB 设备按 `physicalPortID` 挂入；id 优先沿用被吸收 USB 桶的 "usb-0x014"（评级历史
///   延续），否则用端口节点 id（如 "Port-USB-C@2"）；
/// - 无归属 USB 设备会话：按 locationID >> 20 分组，id 形如 "usb-0x014"；
/// - 雷雳会话：按 system_profiler 的 receptacle 编号分组，id 形如 "tb-2"
///   （receptacle 编号与端口节点暂无可靠对应，不做跨总线合并）。
public struct CableSession: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case usb
        case thunderbolt
    }

    /// 稳定会话 id："usb-0x014" / "tb-2"（评级引擎与 UI 选中态都以它为 key）
    public let id: String
    public let kind: Kind
    /// USB 根端口键（locationID >> 20）；雷雳会话为 nil
    public let portKey: UInt32?
    /// 雷雳 receptacle 编号；USB 会话为 nil
    public let receptaclePort: Int?
    /// 物理端口控制器名（"Port-USB-C@1"，与 USBCPortSnapshot.portID 配对；未知时为 nil）
    public let physicalPortID: String?
    /// 完整展示名，如 "USB 端口 0x014" / "雷雳端口 2"
    public let portLabel: String
    public let usbDevices: [USBDeviceSnapshot]
    public let thunderboltDevices: [ThunderboltDeviceSnapshot]

    public init(id: String,
                kind: Kind,
                portKey: UInt32? = nil,
                receptaclePort: Int? = nil,
                physicalPortID: String? = nil,
                portLabel: String,
                usbDevices: [USBDeviceSnapshot] = [],
                thunderboltDevices: [ThunderboltDeviceSnapshot] = []) {
        self.id = id
        self.kind = kind
        self.portKey = portKey
        self.receptaclePort = receptaclePort
        self.physicalPortID = physicalPortID
        self.portLabel = portLabel
        self.usbDevices = usbDevices
        self.thunderboltDevices = thunderboltDevices
    }

    /// 会话内观测到的最高 USB 协商速率
    public var topUSBSpeed: USBSpeed? {
        usbDevices.compactMap(\.speed).max { $0.bitsPerSecond < $1.bitsPerSecond }
    }

    /// 会话内的设备总数（USB + 雷雳）
    public var deviceCount: Int { usbDevices.count + thunderboltDevices.count }

    /// 短标签，用于菜单栏等窄空间："USB-C·@1" / "USB·0x014" / "雷雳·2"
    public var shortPortLabel: String {
        switch kind {
        case .usb:
            if let portID = physicalPortID {
                let type = PortGrouping.portTypeName(fromPortID: portID)
                if let at = portID.firstIndex(of: "@") { return "\(type)·\(portID[at...])" }
                return type
            }
            if let key = portKey, key != 0 { return String(format: "USB·0x%03x", key) }
            return "USB·?"
        case .thunderbolt:
            if let port = receptaclePort, port != 0 { return "雷雳·\(port)" }
            return "雷雳·?"
        }
    }
}
