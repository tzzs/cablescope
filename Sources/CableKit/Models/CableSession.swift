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
    /// 端口形态名（"USB-C" / "MagSafe 3"），**仅端口节点会话有值**。
    ///
    /// nil 不等于"形态未知"，而是"这个会话不是从端口节点建出来的"——设备桶自己报的
    /// `physicalPortID` 配不上任何端口节点时就是这种情况，此时展示名按 `portKey`
    /// 走十六进制形式（沿用改造前的行为，见 `portLabel(locale:)`）。
    public let portType: String?
    public let usbDevices: [USBDeviceSnapshot]
    public let thunderboltDevices: [ThunderboltDeviceSnapshot]

    public init(id: String,
                kind: Kind,
                portKey: UInt32? = nil,
                receptaclePort: Int? = nil,
                physicalPortID: String? = nil,
                portType: String? = nil,
                usbDevices: [USBDeviceSnapshot] = [],
                thunderboltDevices: [ThunderboltDeviceSnapshot] = []) {
        self.id = id
        self.kind = kind
        self.portKey = portKey
        self.receptaclePort = receptaclePort
        self.physicalPortID = physicalPortID
        self.portType = portType
        self.usbDevices = usbDevices
        self.thunderboltDevices = thunderboltDevices
    }

    /// 会话内观测到的最高 USB 协商速率
    public var topUSBSpeed: USBSpeed? {
        usbDevices.compactMap(\.speed).max { $0.bitsPerSecond < $1.bitsPerSecond }
    }

    /// 会话内的设备总数（USB + 雷雳）
    public var deviceCount: Int { usbDevices.count + thunderboltDevices.count }

    // MARK: - 展示名（在渲染时按调用方语言生成，不进快照）
    //
    // 这两个展示名过去是 `portLabel: String` 存进快照的预拼字符串，语言在聚合那一刻
    // 就被写死了——App 切换语言只换得掉自己那层文案，换不掉从 CableKit 带过来的这串，
    // 于是英文界面里混着 "USB-C 端口 @2"。改成按 `Locale` 现算的方法后，语言由渲染方
    // 决定；快照里只留结构化字段（kind / portKey / receptaclePort / physicalPortID /
    // portType），谁都能再拼出自己语言的展示名。

    /// 完整展示名，如 "USB-C 端口 @2" / "USB 端口 0x014" / "雷雳端口 2"。
    ///
    /// 分支依据是 `portType` 而不是 `physicalPortID`：设备自报的 `physicalPortID` 配不上
    /// 端口节点时仍会留在会话里（`portType` 为 nil），那种会话改造前就是按 portKey 展示的，
    /// 这里保持一致。
    public func portLabel(locale: Locale) -> String {
        switch kind {
        case .usb:
            if let type = portType {
                guard let portID = physicalPortID, let at = portID.firstIndex(of: "@") else {
                    return KitLocalization.string(template: "%@ 端口", locale: locale, args: type)
                }
                return KitLocalization.string(template: "%@ 端口 %@", locale: locale,
                                              args: type, String(portID[at...]))
            }
            if let key = portKey, key != 0 {
                return KitLocalization.string(template: "USB 端口 %@", locale: locale,
                                              args: String(format: "0x%03x", key))
            }
            return KitLocalization.string("USB 端口（未知）", locale: locale)
        case .thunderbolt:
            if let port = receptaclePort, port != 0 {
                return KitLocalization.string(template: "雷雳端口 %@", locale: locale, args: String(port))
            }
            return KitLocalization.string("雷雳端口（未知）", locale: locale)
        }
    }

    /// 短标签，用于菜单栏等窄空间："USB-C·@1" / "USB·0x014" / "雷雳·2"。
    ///
    /// 与 `portLabel(locale:)` 的分支依据有意不同：短标签一直是"有 `physicalPortID` 就优先
    /// 用形态名"，即使该端口配不上节点，窄空间里 "USB-C·@1" 也比 "USB·0x141" 好认。
    public func shortPortLabel(locale: Locale) -> String {
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
            if let port = receptaclePort, port != 0 {
                return KitLocalization.string(template: "雷雳·%@", locale: locale, args: String(port))
            }
            return KitLocalization.string("雷雳·?", locale: locale)
        }
    }
}
