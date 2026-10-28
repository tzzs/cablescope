import Foundation
import IOKit
import IOKit.ps

/// 电源/充电状态（IORegistry `AppleSmartBattery` 为主，IOPowerSources 为备用电量来源）。
///
/// 键名均已在本机（Apple Silicon，macOS 26 / Xcode 26 SDK）`ioreg -r -c AppleSmartBattery` 验证：
/// - 顶层标量：`Amperage`(mA，电池侧)、`Voltage`(mV，电池电压)、`ExternalConnected`、
///   `IsCharging`、`CurrentCapacity`、`MaxCapacity`、`CycleCount`；`AdapterVoltage` 通常不存在于顶层
/// - `AdapterDetails` 字典（本机实测样例）：`AdapterVoltage=20000`、`Current=5000`（协商合同电流）、
///   `Watts=100`、`Description="pd charger"`、`UsbHvcMenu`…
///   → `adapterVoltageMV` 回退到 AdapterDetails.AdapterVoltage
///   → `pdContract` 取合同值（AdapterDetails.AdapterVoltage×Current，如 20V×5A=100W 能力）；
///     协商电流（Current）读不到时**不构造合同**——顶层 Amperage 不是合同电流，不能拿来用
/// - 拔掉电源：ExternalConnected=No → 快照 isCharging=false 且电压/电流/合同均为 nil。
/// - 已接通但暂停充电（电量保持/优化充电暂停，如 86% 时 IsCharging=No 而 ExternalConnected=Yes）：
///   isCharging=false 但 externalConnected=true，消费方须用 externalConnected 而非 isCharging
///   判断"是否插电"。
///
/// **顶层 `Amperage` 测的是电池侧电流，不是流过线缆的电流。** 本机实测佐证：100W 充电器
/// 接入、电池 100% 满电时，`AdapterDetails` 报 `Current=5000 / Watts=100`，而顶层
/// `Amperage` 读数为 **0**——系统直接从适配器取电，电流不经过电池。推论：把
/// `Amperage` 称为"实际抽流"会让人以为它能反映线缆承载的电流；它其实是"流入电池的电流"，
/// 满电时恒为 0、暂停充电时可为负（电池侧微小放电）。任何拿它推断线缆能力的逻辑都要
/// 记住这个量纲。
public final class PowerService: PowerServiceProtocol {
    public init() {}

    public func currentPower() async -> PowerSnapshot? {
        await Task.detached(priority: .utility) {
            Self.readPowerSnapshot()
        }.value
    }

    // MARK: - 同步读取核心

    private static func readPowerSnapshot() -> PowerSnapshot? {
        guard let battery = readSmartBattery() else {
            // 主路径失败（如未来设备改名）时退回 IOPS 电量信息，尽力给出最小快照。
            return PowerParsing.fallbackFromIOPS()
        }
        return battery
    }

    private static func readSmartBattery() -> PowerSnapshot? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        // IORegistryEntryCreateCFProperties 以 Unmanaged 出参返回 +1 引用：
        // 统一用 defer release，成功/失败路径都不泄漏。
        var propertiesRef: Unmanaged<CFMutableDictionary>?
        let kr = IORegistryEntryCreateCFProperties(service, &propertiesRef, kCFAllocatorDefault, 0)
        defer { propertiesRef?.release() }
        guard kr == KERN_SUCCESS, let ref = propertiesRef else { return nil }
        let props = ref.takeUnretainedValue() as? [String: Any] ?? [:]

        return PowerParsing.parse(props: props)
    }
}

/// IORegistry 属性字典 → PowerSnapshot 的纯解析逻辑（internal 便于单测，无 IOKit 依赖）。
enum PowerParsing {
    static func parse(props: [String: Any]) -> PowerSnapshot {
        let externalConnected = boolValue(forKey: "ExternalConnected", in: props) ?? false
        let isCharging = boolValue(forKey: "IsCharging", in: props) ?? false

        let adapterDetails = props["AdapterDetails"] as? [String: Any]
        // 实测（macOS 26，Apple Silicon）：顶层通常没有 `AdapterVoltage` 键，该键只在
        // AdapterDetails 字典里；顶层 `Amperage` 是**流入电池**的电流（不是线缆电流）。
        let voltageMV = intValue(forKey: "AdapterVoltage", in: props)
            ?? adapterDetails.flatMap { intValue(forKey: "AdapterVoltage", in: $0) }
        let amperageMA = intValue(forKey: "Amperage", in: props)
        // 电池电压：功率换算必须与电池电流同域。`Voltage` 是标准键，
        // `AppleRawBatteryVoltage` 在部分系统上才是原始值（两者本机实测一致）。
        let batteryVoltageMV = intValue(forKey: "Voltage", in: props)
            ?? intValue(forKey: "AppleRawBatteryVoltage", in: props)

        // pdContract 是协商的 PD 合同（能力上限，如 20V×5A=100W），区别于电池侧功率。
        //
        // **合同只在读到协商读数时才构造**（宁缺勿造）：
        // - 电压：AdapterDetails.AdapterVoltage 优先，顶层 AdapterVoltage 兜底——两者都是
        //   适配器输出电压，语义上就是合同电压；
        // - 电流：只认 AdapterDetails.Current（协商合同电流）。顶层 `Amperage` 是**瞬时实际
        //   电流**，拿它兜底会拼出一个"电池侧功率冒充合同"的假合同——下游诊断拿合同功率与
        //   功率比较时恒判"充电器满档输出"，还会拿瞬时值去比适配器档位、把线缆误判成瓶颈。
        let contractVoltageMV = adapterDetails.flatMap { intValue(forKey: "AdapterVoltage", in: $0) }
            ?? intValue(forKey: "AdapterVoltage", in: props)
        let contractAmperageMA = adapterDetails.flatMap { intValue(forKey: "Current", in: $0) }

        var pdContract: PDContract?
        var adapterDescription: String?
        if externalConnected {
            if let v = contractVoltageMV, let a = contractAmperageMA, v > 0, a > 0 {
                pdContract = PDContract(voltageMV: v, currentMA: a)
            }
            if let description = adapterDetails?["Description"] as? String, !description.isEmpty {
                adapterDescription = description
            }
        }

        let charging = isCharging && externalConnected

        return PowerSnapshot(
            isCharging: charging,
            batteryPercent: batteryPercent(from: props),
            // 未接适配器时适配器电压/电流无意义，置 nil（顶层可能有 0 残留值）。
            // 电池电压是电池自身的属性，插不插电都有意义，照常保留。
            adapterVoltageMV: externalConnected ? voltageMV : nil,
            batteryAmperageMA: externalConnected ? amperageMA : nil,
            batteryVoltageMV: batteryVoltageMV,
            pdContract: pdContract,
            adapterDescription: adapterDescription,
            cycleCount: intValue(forKey: "CycleCount", in: props),
            externalConnected: externalConnected,
            rawProperties: IORegistryValue.dictionary(from: props)
        )
    }

    /// 电量：优先 AppleSmartBattery 的 CurrentCapacity/MaxCapacity；异常时退回 IOPS。
    static func batteryPercent(from props: [String: Any]) -> Double? {
        if let current = intValue(forKey: "CurrentCapacity", in: props),
           let maxCapacity = intValue(forKey: "MaxCapacity", in: props), maxCapacity > 0 {
            let percent = Double(current) / Double(maxCapacity) * 100
            return min(max(percent, 0), 100)
        }
        return iopsBatteryPercent()
    }

    // MARK: - IOPS 备用来源

    /// AppleSmartBattery 不可用时的最小快照（仅电量）。
    static func fallbackFromIOPS() -> PowerSnapshot? {
        guard let percent = iopsBatteryPercent() else { return nil }
        return PowerSnapshot(isCharging: false,
                             batteryPercent: percent,
                             adapterVoltageMV: nil,
                             batteryAmperageMA: nil,
                             pdContract: nil,
                             adapterDescription: nil,
                             cycleCount: nil)
    }

    private static func iopsBatteryPercent() -> Double? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            // 内部电池：kIOPSTransportTypeKey == kIOPSInternalBatteryType
            if let transport = description[kIOPSTransportTypeKey] as? String,
               transport == kIOPSInternalBatteryType,
               let capacity = description[kIOPSCurrentCapacityKey] as? Int {
                return Double(min(max(capacity, 0), 100))
            }
        }
        return nil
    }

    // MARK: - 取值辅助

    private static func intValue(forKey key: String, in dict: [String: Any]) -> Int? {
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

    private static func boolValue(forKey key: String, in dict: [String: Any]) -> Bool? {
        guard let raw = dict[key] else { return nil }
        switch raw {
        case let b as Bool: return b
        case let n as NSNumber: return n.boolValue
        case let s as String:
            // ioreg 文本中布尔表现为 Yes/No；CFProperties 里通常是 CFBoolean，这里兜底字符串。
            switch s.lowercased() {
            case "yes", "true", "1": return true
            case "no", "false", "0": return false
            default: return nil
            }
        default: return nil
        }
    }
}
