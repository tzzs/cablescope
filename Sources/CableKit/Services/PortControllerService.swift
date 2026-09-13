import Foundation
import IOKit

// MARK: - USB-C 端口控制器服务（AppleHPM / AppleTC 适配）
//
// 枚举 IORegistry 上的 USB-C / MagSafe 端口控制器节点及其子树：
//   Port-USB-C@N            ← AppleHPMInterfaceType10/11/12/18（或老机型 AppleTCControllerType10/11）
//   ├─ CC                   ← CC 传输层
//   │   ├─ SOP              ← 端口对端设备身份（充电器/设备/坞站的 Discover Identity）
//   │   └─ SOP'             ← 线缆近端 e-marker 身份（速度/电流评级/VID）
//   └─ Power In
//       └─ USB-PD           ← PD 档位表 + 当前协商档（WinningPowerSourceOption）
//
// 类本身无状态（所有 IOKit 句柄都是调用内局部变量，用完即 IOObjectRelease），天然满足 Sendable。
// Gate A 已验证：以上读取在 App Sandbox（app-sandbox + device.usb）下与明文权限结果一致。
public final class PortControllerService: PortControllerServiceProtocol {
    /// 依序尝试的端口控制器类名。命中顺序不敏感（不同代际机型只会有其一族存活）。
    public static let controllerClasses: [String] = [
        "AppleHPMInterfaceType10",
        "AppleHPMInterfaceType11",
        "AppleHPMInterfaceType12",
        "AppleHPMInterfaceType18",
        "AppleTCControllerType10",
        "AppleTCControllerType11",
    ]

    public init() {}

    public func listPorts() async throws -> [USBCPortSnapshot] {
        await Task.detached(priority: .utility) {
            Self.enumeratePorts()
        }.value
    }

    // MARK: - 同步枚举核心（无 self 捕获，纯静态）

    private static func enumeratePorts() -> [USBCPortSnapshot] {
        var ports: [USBCPortSnapshot] = []
        for className in controllerClasses {
            var iterator: io_iterator_t = 0
            let matching = IOServiceMatching(className)
            guard matching != nil else { continue }
            let kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
            guard kr == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iterator) }

            while true {
                let entry = IOIteratorNext(iterator)
                if entry == 0 { break }
                defer { IOObjectRelease(entry) }
                if let port = readPort(from: entry, controllerClass: className) {
                    ports.append(port)
                }
            }
        }
        // 稳定排序：按节点名（Port-USB-C@1 < Port-USB-C@2 < Port-MagSafe 3@1 的字典序即可读）。
        return ports.sorted { $0.portID < $1.portID }
    }

    private static func readPort(from entry: io_registry_entry_t,
                                 controllerClass: String) -> USBCPortSnapshot? {
        guard let properties = cfProperties(of: entry) else { return nil }
        // 端口 ID 取 IOService plane 路径的最后一段（"Port-USB-C@1"）——
        // 与 USB 设备祖先链上 UsbIOPort 路径的末段一致，是端口配对的 key；
        // IORegistryEntryGetName 只返回 "Port-USB-C"，缺 @N 位置段，不能直接用。
        var pathBuffer = [CChar](repeating: 0, count: 512)
        let portID: String
        if IORegistryEntryGetPath(entry, kIOServicePlane, &pathBuffer) == KERN_SUCCESS {
            let path = String(cString: pathBuffer)
            portID = path.split(separator: "/").last.map(String.init) ?? ""
        } else {
            portID = ""
        }
        guard !portID.isEmpty else { return nil }

        // 子树收集：SOP / SOP' / USB-PD 节点挂在更深层（CC、Power In 之下）。
        // 注意：这些 IOPort 节点上 IORegistryEntryGetChildEntry 会返回成功但空迭代器
        // （真机验证），必须用 kIORegistryIterateRecursively 的递归迭代器。
        var partnerNodes: [[String: Any]] = []
        var eMarkerNodes: [[String: Any]] = []
        var powerSourceNodes: [[String: Any]] = []
        if let iterator = recursiveChildIterator(of: entry) {
            defer { IOObjectRelease(iterator) }
            while true {
                let child = IOIteratorNext(iterator)
                if child == 0 { break }
                defer { IOObjectRelease(child) }
                var classBuffer = [CChar](repeating: 0, count: 128)
                guard IOObjectGetClass(child, &classBuffer) == KERN_SUCCESS else { continue }
                let className = String(cString: classBuffer)
                switch className {
                case PortParsing.sopPartnerClass:
                    if let props = cfProperties(of: child) { partnerNodes.append(props) }
                case PortParsing.sopNearMarkerClass, PortParsing.sopFarMarkerClass:
                    if let props = cfProperties(of: child) { eMarkerNodes.append(props) }
                case PortParsing.powerSourceClass:
                    if let props = cfProperties(of: child) { powerSourceNodes.append(props) }
                default:
                    continue
                }
            }
        }

        return PortParsing.parsePort(portID: portID,
                                     controllerClass: controllerClass,
                                     properties: properties,
                                     partnerProperties: partnerNodes.first,
                                     eMarkerProperties: eMarkerNodes.first,
                                     powerSourceProperties: preferredPowerSource(powerSourceNodes))
    }

    /// 端口子树的递归迭代器（含全部后代）。
    private static func recursiveChildIterator(of entry: io_registry_entry_t) -> io_iterator_t? {
        var iterator: io_iterator_t = 0
        let kr = IORegistryEntryCreateIterator(entry, kIOServicePlane,
                                               UInt32(kIORegistryIterateRecursively), &iterator)
        guard kr == KERN_SUCCESS else { return nil }
        return iterator
    }

    /// 优先取 USB-PD 节点（档位最全）；缺失时退回第一个有档位的节点。
    private static func preferredPowerSource(_ nodes: [[String: Any]]) -> [String: Any]? {
        if let pd = nodes.first(where: { ($0["PowerSourceName"] as? String) == "USB-PD" }) {
            return pd
        }
        return nodes.first { ($0["PowerSourceOptions"] as? [Any])?.isEmpty == false }
    }

    private static func cfProperties(of entry: io_registry_entry_t) -> [String: Any]? {
        var propertiesRef: Unmanaged<CFMutableDictionary>?
        let kr = IORegistryEntryCreateCFProperties(entry, &propertiesRef, kCFAllocatorDefault, 0)
        defer { propertiesRef?.release() }
        guard kr == KERN_SUCCESS, let ref = propertiesRef else { return nil }
        return ref.takeUnretainedValue() as? [String: Any]
    }
}

// MARK: - 纯解析逻辑（internal 便于单测，无 IOKit 依赖）

enum PortParsing {
    static let sopPartnerClass = "IOPortTransportComponentCCUSBPDSOP"
    static let sopNearMarkerClass = "IOPortTransportComponentCCUSBPDSOPp"
    static let sopFarMarkerClass = "IOPortTransportComponentCCUSBPDSOPpp"
    static let powerSourceClass = "IOPortFeaturePowerSource"

    // MARK: 端口节点

    static func parsePort(portID: String,
                          controllerClass: String,
                          properties: [String: Any],
                          partnerProperties: [String: Any]?,
                          eMarkerProperties: [String: Any]?,
                          powerSourceProperties: [String: Any]?) -> USBCPortSnapshot {
        USBCPortSnapshot(
            portID: portID,
            controllerClass: controllerClass,
            portType: stringValue(forKey: "PortTypeDescription", in: properties),
            plugOrientation: intValue(forKey: "PlugOrientation", in: properties),
            isActive: boolValue(forKey: "ConnectionActive", in: properties) ?? false,
            hasActiveCable: boolValue(forKey: "ActiveCable", in: properties) ?? false,
            connectionCount: intValue(forKey: "ConnectionCount", in: properties),
            transportsSupported: stringArray(forKey: "TransportsSupported", in: properties),
            transportsProvisioned: stringArray(forKey: "TransportsProvisioned", in: properties),
            featuresEnabled: stringArray(forKey: "FeaturesEnabled", in: properties),
            eMarker: eMarkerProperties.flatMap(parseEMarker),
            partner: partnerProperties.flatMap(parsePartner),
            powerSource: powerSourceProperties.flatMap(parsePowerSource)
        )
    }

    // MARK: SOP'（线缆 e-marker）

    static func parseEMarker(_ properties: [String: Any]) -> EMarkerSnapshot? {
        // 身份字段优先取顶层（Apple 会平铺一份），缺失时回退 Metadata 字典。
        let metadata = properties["Metadata"] as? [String: Any] ?? [:]
        let vdos = vdoArray(in: properties) ?? vdoArray(in: metadata)
        // 空身份（例如对端尚未响应 SOP'）不产出 e-marker 快照。
        guard vdos != nil || vendorID(from: properties, metadata: metadata) != nil
            || stringValue(forKey: "Product Type Description", in: properties) != nil
            || stringValue(forKey: "Product Type Description", in: metadata) != nil else { return nil }

        let productType = intValue(forKey: "Product Type", in: properties)
            ?? intValue(forKey: "Product Type", in: metadata)

        return EMarkerSnapshot(
            vendorID: vendorID(from: properties, metadata: metadata),
            productID: uint32Value(forKey: "Product ID", in: properties)
                ?? uint32Value(forKey: "Product ID", in: metadata),
            productType: productType,
            productTypeDescription: stringValue(forKey: "Product Type Description", in: properties)
                ?? stringValue(forKey: "Product Type Description", in: metadata),
            vdos: vdos ?? []
        )
    }

    // MARK: SOP（对端设备身份）

    static func parsePartner(_ properties: [String: Any]) -> PartnerIdentitySnapshot? {
        let metadata = properties["Metadata"] as? [String: Any] ?? [:]
        let vdos = vdoArray(in: properties) ?? vdoArray(in: metadata)
        let vendor = vendorID(from: properties, metadata: metadata)
        guard vdos != nil || vendor != nil else { return nil }
        return PartnerIdentitySnapshot(
            vendorID: vendor,
            productID: uint32Value(forKey: "Product ID", in: properties)
                ?? uint32Value(forKey: "Product ID", in: metadata),
            vdos: vdos ?? []
        )
    }

    // MARK: Power In/USB-PD（PD 档位）

    static func parsePowerSource(_ properties: [String: Any]) -> PDOPortPowerSnapshot? {
        guard let name = stringValue(forKey: "PowerSourceName", in: properties) else { return nil }
        // 实测该属性可能是无序 Set（__NSCFSet）：按电压升序输出保证展示稳定。
        let rawOptions = anyCollection(forKey: "PowerSourceOptions", in: properties) ?? []
        let options = rawOptions.compactMap { ($0 as? [String: Any]).flatMap(parsePhase) }
            .sorted { $0.voltageMV < $1.voltageMV }
        let winning = (properties["WinningPowerSourceOption"] as? [String: Any]).flatMap(parsePhase)
        guard !options.isEmpty || winning != nil else { return nil }
        return PDOPortPowerSnapshot(sourceName: name, options: options, winning: winning)
    }

    static func parsePhase(_ dict: [String: Any]) -> PDOPhase? {
        guard let voltage = intValue(forKey: "Voltage (mV)", in: dict),
              let current = intValue(forKey: "Max Current (mA)", in: dict) else { return nil }
        let powerMW = intValue(forKey: "Max Power (mW)", in: dict) ?? voltage * current / 1000
        return PDOPhase(voltageMV: voltage, maxCurrentMA: current, maxPowerMW: powerMW,
                        uuid: stringValue(forKey: "UUID", in: dict))
    }

    // MARK: UsbIOPort 路径 → 端口 ID（USBService 配对用）

    /// "IOService:/…/AppleHPMDeviceHALType3@C/Port-USB-C@1" → "Port-USB-C@1"
    static func portID(fromUsbIOPortPath path: String) -> String? {
        let last = path.split(separator: "/").last.map(String.init) ?? ""
        guard last.hasPrefix("Port-") else { return nil }
        return last
    }

    // MARK: 取值辅助

    static func stringValue(forKey key: String, in dict: [String: Any]) -> String? {
        dict[key] as? String
    }

    static func intValue(forKey key: String, in dict: [String: Any]) -> Int? {
        guard let raw = dict[key] else { return nil }
        switch raw {
        case let n as Int: return n
        case let n as Int32: return Int(n)
        case let n as Int64: return Int(exactly: n)
        case let n as UInt32: return Int(n)
        case let n as NSNumber: return n.intValue
        default: return nil
        }
    }

    static func uint32Value(forKey key: String, in dict: [String: Any]) -> UInt32? {
        guard let value = intValue(forKey: key, in: dict), value >= 0,
              value <= Int64(UInt32.max) else { return nil }
        return UInt32(value)
    }

    static func boolValue(forKey key: String, in dict: [String: Any]) -> Bool? {
        guard let raw = dict[key] else { return nil }
        switch raw {
        case let b as Bool: return b
        case let n as NSNumber: return n.boolValue
        default: return nil
        }
    }

    /// IORegistry 的集合属性不一定是数组：`PowerSourceOptions` 实测返回的是
    /// CFSet（__NSCFSet，真机验证），Transports 则是普通数组——两者都接。
    /// 注意 Set 无序，调用方需要稳定顺序时自行排序。
    static func anyCollection(forKey key: String, in dict: [String: Any]) -> [Any]? {
        guard let raw = dict[key] else { return nil }
        if let array = raw as? [Any] { return array }
        if let set = raw as? NSSet { return Array(set) }
        return nil
    }

    static func stringArray(forKey key: String, in dict: [String: Any]) -> [String] {
        anyCollection(forKey: key, in: dict)?.compactMap { $0 as? String } ?? []
    }

    /// Vendor ID 在顶层与 Metadata 里都可能出现；0 视为「未上报」但仍然返回（调用方可识别）。
    static func vendorID(from properties: [String: Any], metadata: [String: Any]) -> UInt32? {
        uint32Value(forKey: "Vendor ID", in: properties)
            ?? uint32Value(forKey: "Vendor ID", in: metadata)
    }

    /// VDO 数组：线上字节序为 little-endian（PD 报文 32 位对象 LSB 先传），
    /// ioreg 里的 <42400800> 按小端解读才与 Apple 平铺的 Product Type 等字段自洽（已真机验证）。
    static func vdoArray(in dict: [String: Any]) -> [UInt32]? {
        guard let raw = anyCollection(forKey: "VDOs", in: dict) else { return nil }
        var result: [UInt32] = []
        for element in raw {
            if let data = element as? Data {
                guard data.count == 4 else { continue }
                let value = data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
                result.append(UInt32(littleEndian: value))
            } else if let number = element as? NSNumber {
                result.append(number.uint32Value)
            }
        }
        return result.isEmpty ? nil : result
    }
}
