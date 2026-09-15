import Foundation
import IOKit

// MARK: - DisplayPort 传输链路服务（IOPortTransportStateDisplayPort）
//
// 与 PortControllerService（AppleHPM 端口控制器）是两棵不同的 IORegistry 子树：这个类
// 表示的是"某个端口上跑的 DP 交替模式链路"本身，不是端口控制器节点，只在真的接了显示器
// 时才存在（真机验证：拔掉显示器节点直接消失，没有"空闲占位"这种状态）。
//
// 真机样例（ioreg -c IOPortTransportStateDisplayPort -l -r）：
//   TransportDescription = "Port-USB-C@1/DisplayPort"
//   ParentPortType = 2 / ParentPortNumber = 1     ← 与 TransportDescription 前缀等价，
//                                                    这里直接解析字符串，不必再猜 ParentPortType
//                                                    的数值编码（2=USB-C 等未经公开文档确认）。
//   Active = Yes / Tunneled = No
//   LinkRateDescription = "8.1 Gbps (HBR3)"
//   ManufacturerName = "AOC" / ProductName = "U27U3XD" / ProductID = 9987 / SerialNumber = 393
public final class DisplayPortTransportService: DisplayPortTransportServiceProtocol {
    static let className = "IOPortTransportStateDisplayPort"

    public init() {}

    public func listDisplayPortLinks() async throws -> [DisplayPortLinkSnapshot] {
        await Task.detached(priority: .utility) {
            Self.enumerateLinks()
        }.value
    }

    // MARK: - 同步枚举核心（无 self 捕获，纯静态）

    private static func enumerateLinks() -> [DisplayPortLinkSnapshot] {
        var iterator: io_iterator_t = 0
        guard let matching = IOServiceMatching(className) else { return [] }
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard kr == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var links: [DisplayPortLinkSnapshot] = []
        while true {
            let entry = IOIteratorNext(iterator)
            if entry == 0 { break }
            defer { IOObjectRelease(entry) }
            guard let properties = cfProperties(of: entry) else { continue }
            links.append(DisplayPortTransportParsing.parseLink(properties))
        }
        // 稳定排序：先按归属端口，再按显示器名。
        return links.sorted {
            ($0.portID ?? "", $0.productName ?? "") < ($1.portID ?? "", $1.productName ?? "")
        }
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

enum DisplayPortTransportParsing {
    static func parseLink(_ properties: [String: Any]) -> DisplayPortLinkSnapshot {
        let metadata = properties["Metadata"] as? [String: Any] ?? [:]
        return DisplayPortLinkSnapshot(
            portID: portID(from: properties),
            isActive: boolValue(forKey: "Active", in: properties) ?? false,
            isTunneled: boolValue(forKey: "Tunneled", in: properties) ?? false,
            linkRateDescription: stringValue(forKey: "LinkRateDescription", in: properties),
            manufacturerName: nonEmptyString(properties["ManufacturerName"])
                ?? nonEmptyString(metadata["ManufacturerName"]),
            productName: nonEmptyString(properties["ProductName"])
                ?? nonEmptyString(metadata["ProductName"]),
            productID: uint32Value(forKey: "ProductID", in: properties)
                ?? uint32Value(forKey: "ProductID", in: metadata),
            serialNumber: uint32Value(forKey: "SerialNumber", in: properties)
                ?? uint32Value(forKey: "SerialNumber", in: metadata)
        )
    }

    /// "Port-USB-C@1/DisplayPort" → "Port-USB-C@1"。不是这个形状（如原生 HDMI 口没有
    /// 对应的 AppleHPM 端口节点）时返回 nil，不强行编出一个归属。
    static func portID(from properties: [String: Any]) -> String? {
        guard let raw = properties["TransportDescription"] as? String,
              raw.hasSuffix("/DisplayPort") else { return nil }
        let prefix = String(raw.dropLast("/DisplayPort".count))
        return prefix.hasPrefix("Port-") ? prefix : nil
    }

    // MARK: 取值辅助（与 PortParsing 同规则：IOKit 数值经 CFNumber 桥接，统一按 NSNumber 兜底）

    static func nonEmptyString(_ value: Any?) -> String? {
        guard let s = value as? String else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func stringValue(forKey key: String, in dict: [String: Any]) -> String? {
        dict[key] as? String
    }

    static func boolValue(forKey key: String, in dict: [String: Any]) -> Bool? {
        switch dict[key] {
        case let b as Bool: return b
        case let n as NSNumber: return n.boolValue
        default: return nil
        }
    }

    static func uint32Value(forKey key: String, in dict: [String: Any]) -> UInt32? {
        guard let raw = dict[key] else { return nil }
        switch raw {
        case let n as UInt32: return n
        case let n as NSNumber:
            let v = n.int64Value
            return (v >= 0 && v <= Int64(UInt32.max)) ? UInt32(v) : nil
        default: return nil
        }
    }
}
