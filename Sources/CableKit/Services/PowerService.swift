import Foundation
import IOKit
import IOKit.ps

/// 电源/充电状态（IORegistry `AppleSmartBattery` 为主，IOPowerSources 为备用电量来源）。
///
/// 键名均已在本机（Apple Silicon，macOS 26 / Xcode 26 SDK）`ioreg -r -c AppleSmartBattery` 验证：
/// - 顶层标量：`Amperage`(mA，实际抽流)、`ExternalConnected`、`IsCharging`、
///   `CurrentCapacity`、`MaxCapacity`、`CycleCount`；`AdapterVoltage` 通常不存在于顶层
/// - `AdapterDetails` 字典（本机实测样例）：`AdapterVoltage=20000`、`Current=5000`（协商合同电流，
///   区别于顶层实际抽流 Amperage）、`Watts=100`、`Description="pd charger"`、`UsbHvcMenu`…
///   → `adapterVoltageMV` 回退到 AdapterDetails.AdapterVoltage（配合顶层 Amperage 得到瞬时功率）
///   → `pdContract` 取合同值（AdapterDetails.AdapterVoltage×Current，如 20V×5A=100W 能力）
/// - 拔掉电源：ExternalConnected=No → 快照 isCharging=false 且电压/电流/合同均为 nil。
public final class PowerService: PowerServiceProtocol {
    public init() {}

    public func currentPower() async throws -> PowerSnapshot? {
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
        // AdapterDetails 字典里；顶层 `Amperage` 才是实际抽流。瞬时功率 =
        // AdapterDetails.AdapterVoltage × 顶层 Amperage（如 20V × 2.0A ≈ 40W）。
        let voltageMV = intValue(forKey: "AdapterVoltage", in: props)
            ?? adapterDetails.flatMap { intValue(forKey: "AdapterVoltage", in: $0) }
        let amperageMA = intValue(forKey: "Amperage", in: props)

        // pdContract 是协商的 PD 合同（能力上限，如 20V×5A=100W），区别于瞬时功率。
        let contractVoltageMV = adapterDetails.flatMap { intValue(forKey: "AdapterVoltage", in: $0) } ?? voltageMV
        let contractAmperageMA = adapterDetails.flatMap { intValue(forKey: "Current", in: $0) } ?? amperageMA

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
            // 未接适配器时电压/电流无意义，置 nil（顶层可能有 0 残留值）。
            adapterVoltageMV: externalConnected ? voltageMV : nil,
            adapterAmperageMA: externalConnected ? amperageMA : nil,
            pdContract: pdContract,
            adapterDescription: adapterDescription,
            cycleCount: intValue(forKey: "CycleCount", in: props)
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
                             adapterAmperageMA: nil,
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
