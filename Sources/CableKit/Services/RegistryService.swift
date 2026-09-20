import Foundation
import IOKit

/// 通用 IORegistry 探查器：按任意 IOKit 类名枚举条目，携带全量属性。
///
/// 与 USBService/PowerService 的「定向提取」互补——本服务不做字段挑选，
/// 原样返回 `IORegistryEntryCreateCFProperties` 的完整字典，供属性检查器
/// （App「IOKit 属性」窗口 / CLI `properties` 子命令）展示与排查。
/// - 条目数上限 `maxEntries`（256）：防止误输入过宽的类名（如 "IOService"）
///   造成海量属性读取拖垮 UI；到达上限即截断并在结果中如实体现。
/// - 类本身无状态（所有 IOKit 句柄都是调用内局部变量，用完即 IOObjectRelease），
///   天然满足 Sendable。
public final class RegistryService: RegistryServiceProtocol {
    /// 单次枚举的条目数上限。
    public static let maxEntries = 256

    /// 常用类名清单（属性检查器的默认选择项；枚举结果可能为空，属正常现象）。
    public static let wellKnownClasses: [WellKnownClass] = [
        WellKnownClass(className: "IOUSBHostDevice", labelKey: "USB 设备"),
        WellKnownClass(className: "IOUSBHostInterface", labelKey: "USB 接口"),
        WellKnownClass(className: "AppleSmartBattery", labelKey: "电源 / 电池"),
        WellKnownClass(className: "AppleHPMInterfaceType10", labelKey: "USB-C 端口控制器"),
        WellKnownClass(className: "AppleHPMInterfaceType11", labelKey: "MagSafe 端口控制器"),
        WellKnownClass(className: "IOPortFeaturePowerSource", labelKey: "PD 电源档位"),
        WellKnownClass(className: "IOPortTransportComponentCCUSBPDSOPp", labelKey: "线缆 e-marker（SOP'）"),
        WellKnownClass(className: "IODisplayConnect", labelKey: "显示器连接"),
        WellKnownClass(className: "IOPortTransportStateDisplayPort", labelKey: "DisplayPort 传输链路"),
        WellKnownClass(className: "IOThunderboltPort", labelKey: "雷电端口"),
    ]

    public init() {}

    public func listEntries(matchingClass className: String) async throws -> [RegistryEntrySnapshot] {
        let trimmed = className.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        // IOKit 同步枚举放 detached 上下文执行，避免阻塞协作线程池/主线程。
        return await Task.detached(priority: .utility) {
            Self.enumerateEntries(matchingClass: trimmed)
        }.value
    }

    // MARK: - 同步枚举核心（无 self 捕获，纯静态）

    private static func enumerateEntries(matchingClass className: String) -> [RegistryEntrySnapshot] {
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching(className)
        guard matching != nil else { return [] }
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        // 成功后 iterator 的所有权转移给我们；失败时 IOServiceGetMatchingServices 内部已释放 matching。
        guard kr == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var entries: [RegistryEntrySnapshot] = []
        while entries.count < maxEntries {
            let entry = IOIteratorNext(iterator)
            if entry == 0 { break }
            defer { IOObjectRelease(entry) }
            if let snapshot = readEntry(from: entry, requestedClass: className) {
                entries.append(snapshot)
            }
        }
        // 稳定排序：按 registryID。
        return entries.sorted { $0.registryID < $1.registryID }
    }

    private static func readEntry(from entry: io_registry_entry_t,
                                  requestedClass: String) -> RegistryEntrySnapshot? {
        var propertiesRef: Unmanaged<CFMutableDictionary>?
        let kr = IORegistryEntryCreateCFProperties(entry, &propertiesRef, kCFAllocatorDefault, 0)
        defer { propertiesRef?.release() }
        guard kr == KERN_SUCCESS, let ref = propertiesRef else { return nil }
        let properties = ref.takeUnretainedValue() as? [String: Any] ?? [:]

        var registryID: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(entry, &registryID)

        return RegistryEntrySnapshot(
            registryID: registryID,
            name: entryName(entry),
            className: objectClass(entry) ?? requestedClass,
            properties: IORegistryValue.dictionary(from: properties)
        )
    }

    private static func entryName(_ entry: io_registry_entry_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 128)
        guard IORegistryEntryGetName(entry, &buffer) == KERN_SUCCESS else { return nil }
        let name = String(cString: buffer)
        return name.isEmpty ? nil : name
    }

    private static func objectClass(_ entry: io_object_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 128)
        guard IOObjectGetClass(entry, &buffer) == KERN_SUCCESS else { return nil }
        let className = String(cString: buffer)
        return className.isEmpty ? nil : className
    }
}

/// 检查器默认类名选项。
public struct WellKnownClass: Hashable, Sendable {
    public let className: String
    /// 中文原句，同时充当 `Localizable.strings` 的 key；展示请走 `label(locale:)`。
    ///
    /// 保留裸字段而不是彻底私有化：`Hashable` 语义与去重都依赖它，且中文原句就是
    /// 这套表的规范形式（见 KitLocalization 的注释）。
    public let labelKey: String

    public init(className: String, labelKey: String) {
        self.className = className
        self.labelKey = labelKey
    }

    /// 按调用方语言取展示名；查表落空退回中文原句。
    public func label(locale: Locale) -> String {
        KitLocalization.string(labelKey, locale: locale)
    }
}
