import Foundation
import IOKit

/// USB 设备枚举（IOKit IOUSBHostDevice 适配）。
///
/// 实现要点（见 Docs/02-技术架构.md / 03-数据获取指南.md）：
/// - `IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator)`
///   匹配的是整棵 Registry plane 上所有 `IOUSBHostDevice` 实例（包括挂在 hub 下的设备与 hub 本身），
///   因此**无需**按 hub 递归遍历——迭代器天然是全局扁平匹配。
/// - 属性来自 `IORegistryEntryCreateCFProperties`：Speed(bps)/LocationID/USB Product Name/
///   USB Vendor Name/idVendor/idProduct/USB Serial Number/bcdUSB。
/// - 无设备插入时迭代器为空，返回空数组（本机已验证 SPUSBDataType 为空数组的场景）。
/// - 类本身无状态（所有 IOKit 句柄都是调用内局部变量，用完即 IOObjectRelease），
///   因此天然满足 Sendable。
public final class USBService: USBServiceProtocol {
    public init() {}

    public func listUSBDevices() async throws -> [USBDeviceSnapshot] {
        // IOKit 同步枚举放 detached 上下文执行，避免阻塞协作线程池/主线程。
        await Task.detached(priority: .utility) {
            Self.enumerateUSBDevices()
        }.value
    }

    // MARK: - 同步枚举核心（无 self 捕获，纯静态）

    private static func enumerateUSBDevices() -> [USBDeviceSnapshot] {
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("IOUSBHostDevice")
        guard matching != nil else { return [] }
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        // 成功后 iterator 的所有权转移给我们；失败时 IOServiceGetMatchingServices 内部已释放 matching。
        guard kr == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var devices: [USBDeviceSnapshot] = []
        while true {
            let entry = IOIteratorNext(iterator)
            if entry == 0 { break }
            defer { IOObjectRelease(entry) }
            if let snapshot = readDevice(from: entry) {
                devices.append(snapshot)
            }
        }
        // 稳定排序：按物理端口 + registryID，方便 UI/聚合按端口观察。
        return devices.sorted { ($0.locationID, $0.registryID) < ($1.locationID, $1.registryID) }
    }

    private static func readDevice(from entry: io_registry_entry_t) -> USBDeviceSnapshot? {
        // IORegistryEntryCreateCFProperties 以 Unmanaged 出参返回 +1 引用：
        // 统一用 defer release，成功/失败路径都不泄漏。
        var propertiesRef: Unmanaged<CFMutableDictionary>?
        let kr = IORegistryEntryCreateCFProperties(entry, &propertiesRef, kCFAllocatorDefault, 0)
        defer { propertiesRef?.release() }
        guard kr == KERN_SUCCESS, let ref = propertiesRef else { return nil }
        let properties = ref.takeUnretainedValue() as? [String: Any] ?? [:]

        var registryID: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(entry, &registryID)

        let speedInt = int64Value(forKey: "Speed", in: properties)
        let locationID = uint32Value(forKey: "LocationID", in: properties) ?? 0

        return USBDeviceSnapshot(
            registryID: registryID,
            locationID: locationID,
            productName: stringValue(forKey: "USB Product Name", in: properties),
            vendorName: stringValue(forKey: "USB Vendor Name", in: properties),
            vendorID: uint16Value(forKey: "idVendor", in: properties),
            productID: uint16Value(forKey: "idProduct", in: properties),
            serialNumber: stringValue(forKey: "USB Serial Number", in: properties),
            // bcdUSB 在不同系统版本上可能是 "0210" 字符串，也可能是数字 512（BCD 0x0210）。
            bcdUSB: bcdUSBString(in: properties),
            speed: speedInt.map { USBSpeed(bitsPerSecond: Int($0)) }
        )
    }

    // MARK: - CF/Any 取值辅助

    private static func stringValue(forKey key: String, in dict: [String: Any]) -> String? {
        guard let raw = dict[key] else { return nil }
        return raw as? String
    }

    private static func int64Value(forKey key: String, in dict: [String: Any]) -> Int64? {
        guard let raw = dict[key] else { return nil }
        switch raw {
        case let n as Int: return Int64(n)
        case let n as Int32: return Int64(n)
        case let n as Int64: return n
        case let n as UInt32: return Int64(n)
        case let n as NSNumber: return n.int64Value
        default: return nil
        }
    }

    private static func uint32Value(forKey key: String, in dict: [String: Any]) -> UInt32? {
        guard let value = int64Value(forKey: key, in: dict), value >= 0, value <= UInt32.max else { return nil }
        return UInt32(value)
    }

    private static func uint16Value(forKey key: String, in dict: [String: Any]) -> UInt16? {
        guard let value = int64Value(forKey: key, in: dict), value >= 0, value <= UInt16.max else { return nil }
        return UInt16(value)
    }

    /// bcdUSB：兼容字符串（"0210"）与数字（512 = 0x0210）两种编码方式。
    private static func bcdUSBString(in dict: [String: Any]) -> String? {
        if let s = stringValue(forKey: "bcdUSB", in: dict) { return s }
        guard let n = int64Value(forKey: "bcdUSB", in: dict) else { return nil }
        return String(format: "%04x", n & 0xFFFF)
    }
}
