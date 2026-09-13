import Foundation

// MARK: - USB-C 端口控制器数据契约（Apple Silicon：AppleHPM / AppleTC）
//
// 数据来自 IORegistry 的 USB-C 端口控制器树（本机已验证，App Sandbox 下同样可读，见 Docs/03）：
// - 端口节点：`AppleHPMInterfaceType10/11/12/18`（USB-C / MagSafe 3）或 `AppleTCControllerType10/11`（老机型）；
// - `CC/SOP` 子节点（IOPortTransportComponentCCUSBPDSOP）：端口「对端设备」的 PD Discover Identity；
// - `CC/SOP'` 子节点（…SOPp）：**线缆近端 e-marker** 的 Discover Identity（速度 / 电流评级 / 厂商）；
// - `Power In/USB-PD` 子节点（IOPortFeaturePowerSource）：PD 档位表 + 当前协商档（Winning）。

/// 一个 USB-C / MagSafe 物理端口的状态快照
public struct USBCPortSnapshot: Codable, Hashable, Sendable, Identifiable {
    /// IORegistry 节点名，如 "Port-USB-C@1" / "Port-MagSafe 3@1"。
    /// 与 USB 设备祖先链上 `UsbIOPort` 路径的最后一段一致，是端口配对的 key。
    public let portID: String
    /// 端口控制器类名（AppleHPMInterfaceType10 等）
    public let controllerClass: String
    /// 端口形态（"USB-C" / "MagSafe 3"），来自 PortTypeDescription
    public let portType: String?
    /// 插入方向（1/2 = 正/反插），尽力而为
    public let plugOrientation: Int?
    /// 当前是否有活跃连接（ConnectionActive）
    public let isActive: Bool
    /// 是否检测到活跃线缆（ActiveCable；部分线缆/适配器组合可能为 No 而 isActive 为 Yes）
    public let hasActiveCable: Bool
    /// 累计连接次数
    public let connectionCount: Int?
    /// 支持的传输能力（"CC"/"USB2"/"USB3"/"CIO"/"DisplayPort"…）
    public let transportsSupported: [String]
    /// 已使能的传输能力
    public let transportsProvisioned: [String]
    /// 端口特性（"Power In"/"TRM"/"LDCM"…）
    public let featuresEnabled: [String]
    /// 线缆 e-marker（SOP' 节点；线缆无 e-marker 或未响应时为 nil）
    public let eMarker: EMarkerSnapshot?
    /// 对端设备身份（SOP 节点；充电器/设备的 VID/PID + VDO）
    public let partner: PartnerIdentitySnapshot?
    /// PD 档位信息（Power In/USB-PD 节点）
    public let powerSource: PDOPortPowerSnapshot?

    public init(portID: String,
                controllerClass: String,
                portType: String?,
                plugOrientation: Int?,
                isActive: Bool,
                hasActiveCable: Bool,
                connectionCount: Int?,
                transportsSupported: [String],
                transportsProvisioned: [String],
                featuresEnabled: [String],
                eMarker: EMarkerSnapshot?,
                partner: PartnerIdentitySnapshot?,
                powerSource: PDOPortPowerSnapshot?) {
        self.portID = portID
        self.controllerClass = controllerClass
        self.portType = portType
        self.plugOrientation = plugOrientation
        self.isActive = isActive
        self.hasActiveCable = hasActiveCable
        self.connectionCount = connectionCount
        self.transportsSupported = transportsSupported
        self.transportsProvisioned = transportsProvisioned
        self.featuresEnabled = featuresEnabled
        self.eMarker = eMarker
        self.partner = partner
        self.powerSource = powerSource
    }

    public var id: String { portID }

    /// 是否支持 USB4 / 雷雳数据（Transports 里含 CIO）
    public var supportsThunderboltUSB4: Bool {
        transportsSupported.contains("CIO")
    }
}

/// 线缆 e-marker（SOP' Discover Identity 解析结果）
public struct EMarkerSnapshot: Codable, Hashable, Sendable {
    /// e-marker 芯片上报的厂商 ID（VID）。0 表示未上报（无标 / 便宜的 e-marker 常见）。
    public let vendorID: UInt32?
    public let productID: UInt32?
    /// 线缆产品类型原始值（ID Header 的 USB Product Type）
    public let productType: Int?
    /// Apple 预解析的产品类型描述（"Passive Cable" / "Active Cable" / "EPR Cable"…）
    public let productTypeDescription: String?
    /// 原始 VDO 数组（按线上字节序 little-endian 解为 UInt32）
    public let vdos: [UInt32]

    public init(vendorID: UInt32?,
                productID: UInt32?,
                productType: Int?,
                productTypeDescription: String?,
                vdos: [UInt32]) {
        self.vendorID = vendorID
        self.productID = productID
        self.productType = productType
        self.productTypeDescription = productTypeDescription
        self.vdos = vdos
    }

    // MARK: VDO 位段解码（USB-PD R3.2；位段定义与 Linux 内核 pd_vdo.h 一致，已用真机 VDO 验证）

    /// ID Header VDO 的 USB Product Type（bits [29:27]）：3 = Passive Cable，4 = Active Cable，6 = VPD
    public var decodedProductType: Int? {
        guard let idh = vdos.first else { return nil }
        return Int((idh >> 27) & 0x7)
    }

    /// Cable VDO（Discover Identity 第 4 个对象）的线缆速度档（bits [2:0]）
    public var decodedSpeed: CableSpeedClass? {
        guard let cable = cableVDO else { return nil }
        return CableSpeedClass(rawValue: Int(cable & 0x7))
    }

    /// Cable VDO 的电流评级（bits [6:5]）
    public var decodedCurrentRating: CableCurrentRating? {
        guard let cable = cableVDO else { return nil }
        return CableCurrentRating(rawValue: Int((cable >> 5) & 0x3))
    }

    /// Cable VDO：passive/active 线缆的 Discover Identity 固定 4 个对象，最后一个是 Cable VDO
    private var cableVDO: UInt32? {
        guard vdos.count >= 4 else { return nil }
        return vdos[3]
    }
}

/// 线缆速度档（Cable VDO bits [2:0]，USB-PD R3.2 "USB Highest Speed"）
public enum CableSpeedClass: Int, Codable, Sendable {
    case usb2 = 0
    case usb32Gen1 = 1
    case usb32Gen2 = 2
    case usb4Gen3 = 3
    /// PD 3.2 为 EPR 线缆扩展的档位（内核头未列，best-effort）
    case usb4Gen4 = 4

    public var label: String {
        switch self {
        case .usb2: return "USB 2.0"
        case .usb32Gen1: return "USB 3.2 Gen1（5 Gbps）"
        case .usb32Gen2: return "USB 3.2 Gen2（10 Gbps）"
        case .usb4Gen3: return "USB4 / 雷雳 3（40 Gbps）"
        case .usb4Gen4: return "USB4 Gen4（80 Gbps）"
        }
    }
}

/// 线缆电流评级（Cable VDO bits [6:5]）
public enum CableCurrentRating: Int, Codable, Sendable {
    /// 默认 USB 电流（未标定 3A/5A 的线）
    case usbDefault = 0
    case threeAmp = 1
    case fiveAmp = 2
    /// 保留值（EPR 线缆的 240W 能力用扩展字段表达，不在本位段）
    case reserved = 3

    public var label: String {
        switch self {
        case .usbDefault: return "默认 USB 电流"
        case .threeAmp: return "3A（≤60W）"
        case .fiveAmp: return "5A（≤100W）"
        case .reserved: return "保留值"
        }
    }
}

/// 端口对端设备身份（SOP Discover Identity：充电器 / 设备 / 坞站）
public struct PartnerIdentitySnapshot: Codable, Hashable, Sendable {
    public let vendorID: UInt32?
    public let productID: UInt32?
    public let vdos: [UInt32]

    public init(vendorID: UInt32?, productID: UInt32?, vdos: [UInt32]) {
        self.vendorID = vendorID
        self.productID = productID
        self.vdos = vdos
    }
}

/// 端口 PD 电源信息（IOPortFeaturePowerSource "USB-PD" 节点）
public struct PDOPortPowerSnapshot: Codable, Hashable, Sendable {
    /// 电源名（"USB-PD" / "Brick ID" / "TypeC"）
    public let sourceName: String
    /// 伙伴上报的 PD 档位表（fixed 档；缺 PPS/AVS 原始信息，见 Docs/03 局限说明）
    public let options: [PDOPhase]
    /// 当前协商档（WinningPowerSourceOption；未协商时为 nil）
    public let winning: PDOPhase?

    public init(sourceName: String, options: [PDOPhase], winning: PDOPhase?) {
        self.sourceName = sourceName
        self.options = options
        self.winning = winning
    }

    /// 协商档在档位表中的下标（按 UUID 匹配；匹配不到时按电压+电流兜底）
    public var winningIndex: Int? {
        guard let winning else { return nil }
        if let uuid = winning.uuid,
           let index = options.firstIndex(where: { $0.uuid == uuid }) {
            return index
        }
        return options.firstIndex { $0.voltageMV == winning.voltageMV && $0.maxCurrentMA == winning.maxCurrentMA }
    }
}

/// 单个 PD 档位（fixed option）
public struct PDOPhase: Codable, Hashable, Sendable, Identifiable {
    public let voltageMV: Int
    public let maxCurrentMA: Int
    public let maxPowerMW: Int
    /// 档位 UUID（WinningPowerSourceOption 与 PowerSourceOptions 的配对 key）
    public let uuid: String?

    public init(voltageMV: Int, maxCurrentMA: Int, maxPowerMW: Int, uuid: String?) {
        self.voltageMV = voltageMV
        self.maxCurrentMA = maxCurrentMA
        self.maxPowerMW = maxPowerMW
        self.uuid = uuid
    }

    public var id: String { "\(voltageMV)-\(maxCurrentMA)-\(uuid ?? "noid")" }

    /// 功率 W
    public var watts: Double { Double(maxPowerMW) / 1000.0 }

    /// 如 "20.0V / 5.0A"
    public var voltAmpLabel: String {
        String(format: "%.1fV / %.1fA", Double(voltageMV) / 1000, Double(maxCurrentMA) / 1000)
    }

    /// 如 "20.0V / 5.0A · 100W"
    public var label: String { "\(voltAmpLabel) · \(Int((watts).rounded()))W" }
}
