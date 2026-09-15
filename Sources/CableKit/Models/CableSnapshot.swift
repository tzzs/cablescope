import Foundation

// MARK: - 数据契约（CableScope 全项目的核心值类型）
//
// 这些类型是 CableKit / CLI / App 之间唯一的数据交换契约：
// - CLI/App 只依赖这些类型，不直接触碰 IOKit。
// - 所有类型都是 Codable + Sendable，方便落盘与跨 actor 传递。

/// USB 协商速率（来自 kUSBDevicePropertySpeed，单位 bps）
public struct USBSpeed: Codable, Hashable, Sendable {
    public let bitsPerSecond: Int

    public init(bitsPerSecond: Int) {
        self.bitsPerSecond = bitsPerSecond
    }

    /// 人类可读标签，如 "480 Mbps (USB 2.0 Hi-Speed)"
    public var label: String {
        USBSpeed.humanLabel(forBitsPerSecond: bitsPerSecond)
    }

    /// 按常见速率归类，如 "USB 2.0" / "USB 3.x" / "USB4 / Thunderbolt"
    public var generation: String {
        switch bitsPerSecond {
        case ..<1_500_000: return "Low Speed"
        case ..<480_000_000: return "Full Speed (USB 1.1)"
        case ..<5_000_000_000: return "USB 2.0"
        case ..<10_000_000_000: return "USB 3.x Gen1"
        case ..<20_000_000_000: return "USB 3.x Gen2"
        case ..<40_000_000_000: return "USB 3.x Gen2x2"
        default: return "USB4 / Thunderbolt"
        }
    }

    static func humanLabel(forBitsPerSecond bps: Int) -> String {
        let mbps = Double(bps) / 1_000_000
        if mbps >= 1000 {
            return String(format: "%.0f Gbps", mbps / 1000)
        }
        return String(format: "%.0f Mbps", mbps)
    }
}

/// 单个 USB 设备快照
public struct USBDeviceSnapshot: Codable, Hashable, Sendable, Identifiable {
    /// IORegistry entry id，同一次快照内稳定
    public let registryID: UInt64
    /// 物理端口定位（LocationID），跨快照聚合历史时的 key
    public let locationID: UInt32
    /// 物理端口名（"Port-USB-C@1"，来自祖先链 UsbIOPort 路径；老机型/树形差异时为 nil）
    public let physicalPortID: String?
    public let productName: String?
    public let vendorName: String?
    public let vendorID: UInt16?
    public let productID: UInt16?
    public let serialNumber: String?
    /// USB 规范版本，如 "0210"
    public let bcdUSB: String?
    /// 协商速率
    public let speed: USBSpeed?
    /// IORegistry 全量原始属性（IORegistryEntryCreateCFProperties 的完整字典）
    public let rawProperties: [String: IORegistryValue]

    public init(registryID: UInt64,
                locationID: UInt32,
                physicalPortID: String? = nil,
                productName: String?,
                vendorName: String?,
                vendorID: UInt16?,
                productID: UInt16?,
                serialNumber: String?,
                bcdUSB: String?,
                speed: USBSpeed?,
                rawProperties: [String: IORegistryValue] = [:]) {
        self.registryID = registryID
        self.locationID = locationID
        self.physicalPortID = physicalPortID
        self.productName = productName
        self.vendorName = vendorName
        self.vendorID = vendorID
        self.productID = productID
        self.serialNumber = serialNumber
        self.bcdUSB = bcdUSB
        self.speed = speed
        self.rawProperties = rawProperties
    }

    public var id: UInt64 { registryID }

    // 兼容旧 JSON（无 rawProperties/physicalPortID 键）：缺失时视为空字典/nil。
    private enum CodingKeys: String, CodingKey {
        case registryID, locationID, physicalPortID, productName, vendorName, vendorID, productID
        case serialNumber, bcdUSB, speed, rawProperties
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.registryID = try container.decode(UInt64.self, forKey: .registryID)
        self.locationID = try container.decode(UInt32.self, forKey: .locationID)
        self.physicalPortID = try container.decodeIfPresent(String.self, forKey: .physicalPortID)
        self.productName = try container.decodeIfPresent(String.self, forKey: .productName)
        self.vendorName = try container.decodeIfPresent(String.self, forKey: .vendorName)
        self.vendorID = try container.decodeIfPresent(UInt16.self, forKey: .vendorID)
        self.productID = try container.decodeIfPresent(UInt16.self, forKey: .productID)
        self.serialNumber = try container.decodeIfPresent(String.self, forKey: .serialNumber)
        self.bcdUSB = try container.decodeIfPresent(String.self, forKey: .bcdUSB)
        self.speed = try container.decodeIfPresent(USBSpeed.self, forKey: .speed)
        self.rawProperties = try container.decodeIfPresent([String: IORegistryValue].self, forKey: .rawProperties) ?? [:]
    }
}

/// USB-C PD 充电合同
public struct PDContract: Codable, Hashable, Sendable {
    /// 协商电压 mV
    public let voltageMV: Int
    /// 协商电流 mA
    public let currentMA: Int

    /// 功率 W
    public var watts: Double { Double(voltageMV) / 1000.0 * Double(currentMA) / 1000.0 }

    /// PD 合同 >= 20V/5A ⇒ 线缆必有 e-marker（5A 线）
    public var implies5ACable: Bool { voltageMV >= 20_000 && currentMA >= 5_000 }

    public init(voltageMV: Int, currentMA: Int) {
        self.voltageMV = voltageMV
        self.currentMA = currentMA
    }
}

/// 电源/充电快照（来自 AppleSmartBattery + IOPS）
public struct PowerSnapshot: Codable, Hashable, Sendable {
    /// 正在充电（IsCharging && ExternalConnected）。
    /// 注意：电池保温/优化充电暂停时 IsCharging=false 但已接通电源，用 externalConnected 区分。
    public let isCharging: Bool
    /// 适配器已接通（ExternalConnected），无论是否正在充电
    public let externalConnected: Bool
    /// 电池电量百分比 0-100
    public let batteryPercent: Double?
    /// 当前适配器电压 mV
    public let adapterVoltageMV: Int?
    /// 当前适配器电流 mA
    public let adapterAmperageMA: Int?
    /// PD 合同（若可解析）
    public let pdContract: PDContract?
    /// 适配器描述/PD 协议信息（来自 AdapterDetails，尽力而为）
    public let adapterDescription: String?
    /// 电池循环次数
    public let cycleCount: Int?
    /// IORegistry 全量原始属性（AppleSmartBattery 的完整字典，含 AdapterDetails 嵌套）
    public let rawProperties: [String: IORegistryValue]

    /// 当前充电功率 W
    public var watts: Double? {
        guard let v = adapterVoltageMV, let a = adapterAmperageMA else { return nil }
        return Double(v) / 1000.0 * Double(a) / 1000.0
    }

    public init(isCharging: Bool,
                batteryPercent: Double?,
                adapterVoltageMV: Int?,
                adapterAmperageMA: Int?,
                pdContract: PDContract?,
                adapterDescription: String?,
                cycleCount: Int?,
                externalConnected: Bool = false,
                rawProperties: [String: IORegistryValue] = [:]) {
        self.isCharging = isCharging
        self.externalConnected = externalConnected
        self.batteryPercent = batteryPercent
        self.adapterVoltageMV = adapterVoltageMV
        self.adapterAmperageMA = adapterAmperageMA
        self.pdContract = pdContract
        self.adapterDescription = adapterDescription
        self.cycleCount = cycleCount
        self.rawProperties = rawProperties
    }
}

/// 显示器快照
public struct DisplaySnapshot: Codable, Hashable, Sendable, Identifiable {
    /// CGDirectDisplayID
    public let displayID: UInt32
    public let name: String?
    public let pixelWidth: Int
    public let pixelHeight: Int
    /// 刷新率 Hz
    public let refreshRateHz: Double?
    /// DP 链路速率标签（HBR2 / HBR3 / UHBR10 / UHBR20 ...），尽力而为
    public let linkRateLabel: String?
    public let isMain: Bool
    /// 是否为内置面板（CGDisplayIsBuiltin）。DisplayPort 传输链路只存在于外接显示器，
    /// 匹配时（PortGrouping.matchedDisplay）用它排除内置屏，比用 isMain 更准确
    /// （内置屏未必是主屏，外接屏也可能被设成主屏）。
    public let isBuiltin: Bool
    /// EDID 厂商/型号/序列号（CGDisplayVendorNumber/ModelNumber/SerialNumber）。
    /// 唯一用途是把 `DisplayPortLinkSnapshot`（同样带 EDID 身份）精确匹配到这台
    /// CGDirectDisplayID——匹配不上时才回退为 nil，不是常规展示字段。
    public let vendorNumber: UInt32?
    public let modelNumber: UInt32?
    public let serialNumber: UInt32?

    public init(displayID: UInt32,
                name: String?,
                pixelWidth: Int,
                pixelHeight: Int,
                refreshRateHz: Double?,
                linkRateLabel: String?,
                isMain: Bool,
                isBuiltin: Bool = false,
                vendorNumber: UInt32? = nil,
                modelNumber: UInt32? = nil,
                serialNumber: UInt32? = nil) {
        self.displayID = displayID
        self.name = name
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.refreshRateHz = refreshRateHz
        self.linkRateLabel = linkRateLabel
        self.isMain = isMain
        self.isBuiltin = isBuiltin
        self.vendorNumber = vendorNumber
        self.modelNumber = modelNumber
        self.serialNumber = serialNumber
    }

    public var id: UInt32 { displayID }
    public var resolutionLabel: String { "\(pixelWidth)×\(pixelHeight)" }

    // 兼容旧 JSON（无 isBuiltin/vendorNumber/modelNumber/serialNumber 键）：
    // isBuiltin 缺失按 false 处理，其余缺失按未知（nil）处理。
    private enum CodingKeys: String, CodingKey {
        case displayID, name, pixelWidth, pixelHeight, refreshRateHz, linkRateLabel, isMain
        case isBuiltin, vendorNumber, modelNumber, serialNumber
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.displayID = try container.decode(UInt32.self, forKey: .displayID)
        self.name = try container.decodeIfPresent(String.self, forKey: .name)
        self.pixelWidth = try container.decode(Int.self, forKey: .pixelWidth)
        self.pixelHeight = try container.decode(Int.self, forKey: .pixelHeight)
        self.refreshRateHz = try container.decodeIfPresent(Double.self, forKey: .refreshRateHz)
        self.linkRateLabel = try container.decodeIfPresent(String.self, forKey: .linkRateLabel)
        self.isMain = try container.decode(Bool.self, forKey: .isMain)
        self.isBuiltin = try container.decodeIfPresent(Bool.self, forKey: .isBuiltin) ?? false
        self.vendorNumber = try container.decodeIfPresent(UInt32.self, forKey: .vendorNumber)
        self.modelNumber = try container.decodeIfPresent(UInt32.self, forKey: .modelNumber)
        self.serialNumber = try container.decodeIfPresent(UInt32.self, forKey: .serialNumber)
    }
}

/// 雷电设备快照
public struct ThunderboltDeviceSnapshot: Codable, Hashable, Sendable, Identifiable {
    public let name: String
    public let vendorName: String?
    /// 链路速度标签，如 "Up to 40Gb/s"
    public let linkSpeedLabel: String?
    public let deviceType: String?
    /// 所在物理端口的 receptacle 编号（来自 receptacle_N_tag；旧 JSON / 解析失败时为 nil）
    public let receptaclePort: Int?
    /// 雷雳代际（M3）："雷雳 5" / "雷雳 4 / USB4" / "雷雳 3"；速度标签缺失或无法识别时为 nil
    public let generation: String?
    /// 树内层级（M6）：receptacle 根设备为 0，下挂设备（级联链/坞站下游）逐层 +1；
    /// 旧 JSON / 旧解析数据为 nil（展示时按 0 处理）
    public let depth: Int?

    public init(name: String, vendorName: String?, linkSpeedLabel: String?, deviceType: String?,
                receptaclePort: Int? = nil, generation: String? = nil, depth: Int? = nil) {
        self.name = name
        self.vendorName = vendorName
        self.linkSpeedLabel = linkSpeedLabel
        self.deviceType = deviceType
        self.receptaclePort = receptaclePort
        self.generation = generation
        self.depth = depth
    }

    public var id: String { name + (vendorName ?? "") }

    // 兼容旧 JSON（无 receptaclePort/generation/depth 键）：缺失时视为 nil。
    private enum CodingKeys: String, CodingKey {
        case name, vendorName, linkSpeedLabel, deviceType, receptaclePort, generation, depth
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.vendorName = try container.decodeIfPresent(String.self, forKey: .vendorName)
        self.linkSpeedLabel = try container.decodeIfPresent(String.self, forKey: .linkSpeedLabel)
        self.deviceType = try container.decodeIfPresent(String.self, forKey: .deviceType)
        self.receptaclePort = try container.decodeIfPresent(Int.self, forKey: .receptaclePort)
        self.generation = try container.decodeIfPresent(String.self, forKey: .generation)
        self.depth = try container.decodeIfPresent(Int.self, forKey: .depth)
    }
}

/// 一次完整的线缆状态快照
public struct CableSnapshot: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let usbDevices: [USBDeviceSnapshot]
    public let power: PowerSnapshot?
    public let displays: [DisplaySnapshot]
    public let thunderboltDevices: [ThunderboltDeviceSnapshot]
    /// 按物理端口聚合的线缆会话（UI 一等公民；由 PortGrouping 在采集时组装）
    public let sessions: [CableSession]
    /// USB-C / MagSafe 物理端口控制器状态（AppleHPM/AppleTC；老机型枚举为空属正常）
    public let ports: [USBCPortSnapshot]
    /// DisplayPort 传输链路状态（IOPortTransportStateDisplayPort；无外接显示器接入时为空）。
    /// 按 `physicalPortID` 精确归属外接显示器到具体线缆会话，见 `PortGrouping.displayPortLinks`。
    public let displayPortLinks: [DisplayPortLinkSnapshot]

    public init(id: UUID = UUID(),
                timestamp: Date = Date(),
                usbDevices: [USBDeviceSnapshot],
                power: PowerSnapshot?,
                displays: [DisplaySnapshot],
                thunderboltDevices: [ThunderboltDeviceSnapshot],
                sessions: [CableSession] = [],
                ports: [USBCPortSnapshot] = [],
                displayPortLinks: [DisplayPortLinkSnapshot] = []) {
        self.id = id
        self.timestamp = timestamp
        self.usbDevices = usbDevices
        self.power = power
        self.displays = displays
        self.thunderboltDevices = thunderboltDevices
        self.sessions = sessions
        self.ports = ports
        self.displayPortLinks = displayPortLinks
    }

    // 兼容旧 JSON（无 sessions/ports/displayPortLinks 键）：缺失时视为空数组，
    // sessions/ports 由消费方按需用 PortGrouping 现算。只自定义解码，编码仍用合成实现（新字段完整写出）。
    private enum CodingKeys: String, CodingKey {
        case id, timestamp, usbDevices, power, displays, thunderboltDevices, sessions, ports, displayPortLinks
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.timestamp = try container.decode(Date.self, forKey: .timestamp)
        self.usbDevices = try container.decode([USBDeviceSnapshot].self, forKey: .usbDevices)
        self.power = try container.decodeIfPresent(PowerSnapshot.self, forKey: .power)
        self.displays = try container.decode([DisplaySnapshot].self, forKey: .displays)
        self.thunderboltDevices = try container.decode([ThunderboltDeviceSnapshot].self, forKey: .thunderboltDevices)
        self.sessions = try container.decodeIfPresent([CableSession].self, forKey: .sessions) ?? []
        self.ports = try container.decodeIfPresent([USBCPortSnapshot].self, forKey: .ports) ?? []
        self.displayPortLinks = try container.decodeIfPresent([DisplayPortLinkSnapshot].self,
                                                               forKey: .displayPortLinks) ?? []
    }

    public func toJSON(pretty: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if pretty {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        }
        return try encoder.encode(self)
    }

    public static func fromJSON(_ data: Data) throws -> CableSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CableSnapshot.self, from: data)
    }
}
