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
    public let productName: String?
    public let vendorName: String?
    public let vendorID: UInt16?
    public let productID: UInt16?
    public let serialNumber: String?
    /// USB 规范版本，如 "0210"
    public let bcdUSB: String?
    /// 协商速率
    public let speed: USBSpeed?

    public init(registryID: UInt64,
                locationID: UInt32,
                productName: String?,
                vendorName: String?,
                vendorID: UInt16?,
                productID: UInt16?,
                serialNumber: String?,
                bcdUSB: String?,
                speed: USBSpeed?) {
        self.registryID = registryID
        self.locationID = locationID
        self.productName = productName
        self.vendorName = vendorName
        self.vendorID = vendorID
        self.productID = productID
        self.serialNumber = serialNumber
        self.bcdUSB = bcdUSB
        self.speed = speed
    }

    public var id: UInt64 { registryID }
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
    public let isCharging: Bool
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
                cycleCount: Int?) {
        self.isCharging = isCharging
        self.batteryPercent = batteryPercent
        self.adapterVoltageMV = adapterVoltageMV
        self.adapterAmperageMA = adapterAmperageMA
        self.pdContract = pdContract
        self.adapterDescription = adapterDescription
        self.cycleCount = cycleCount
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

    public init(displayID: UInt32,
                name: String?,
                pixelWidth: Int,
                pixelHeight: Int,
                refreshRateHz: Double?,
                linkRateLabel: String?,
                isMain: Bool) {
        self.displayID = displayID
        self.name = name
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.refreshRateHz = refreshRateHz
        self.linkRateLabel = linkRateLabel
        self.isMain = isMain
    }

    public var id: UInt32 { displayID }
    public var resolutionLabel: String { "\(pixelWidth)×\(pixelHeight)" }
}

/// 雷电设备快照
public struct ThunderboltDeviceSnapshot: Codable, Hashable, Sendable, Identifiable {
    public let name: String
    public let vendorName: String?
    /// 链路速度标签，如 "Up to 40Gb/s"
    public let linkSpeedLabel: String?
    public let deviceType: String?

    public init(name: String, vendorName: String?, linkSpeedLabel: String?, deviceType: String?) {
        self.name = name
        self.vendorName = vendorName
        self.linkSpeedLabel = linkSpeedLabel
        self.deviceType = deviceType
    }

    public var id: String { name + (vendorName ?? "") }
}

/// 一次完整的线缆状态快照
public struct CableSnapshot: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let usbDevices: [USBDeviceSnapshot]
    public let power: PowerSnapshot?
    public let displays: [DisplaySnapshot]
    public let thunderboltDevices: [ThunderboltDeviceSnapshot]

    public init(id: UUID = UUID(),
                timestamp: Date = Date(),
                usbDevices: [USBDeviceSnapshot],
                power: PowerSnapshot?,
                displays: [DisplaySnapshot],
                thunderboltDevices: [ThunderboltDeviceSnapshot]) {
        self.id = id
        self.timestamp = timestamp
        self.usbDevices = usbDevices
        self.power = power
        self.displays = displays
        self.thunderboltDevices = thunderboltDevices
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
