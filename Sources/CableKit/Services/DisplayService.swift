import Foundation
import CoreGraphics
import AppKit

/// 显示器快照（主路径 CoreGraphics，名称/链路速率尽力而为补充）。
///
/// - 主路径：`CGGetOnlineDisplayList` + `CGDisplayCopyDisplayMode`（pixelWidth/pixelHeight/
///   refreshRate 属性）+ `CGMainDisplayID` 判断主屏。无需外部进程。
/// - 显示器名称：`CGDisplayLocalizedName` / `CGDisplayProductName` 在 macOS 26 SDK 中已移除
///   （编译期验证），改用官方替代 `NSScreen.localizedName`（按 CGDirectDisplayID 关联）；
///   无 NSScreen 映射的在线显示器回退到 system_profiler `_name`，再无则 nil。
/// - `linkRateLabel`：本机（仅内置显示器）`system_profiler SPDisplaysDataType -json` 的字段
///   全集中**没有** DP link rate 字段（已实测），因此实现按"在 ndrv 条目里查找键名含 link
///   的稳定字段"的通用规则尽力解析（外接 DisplayPort 显示器在部分系统版本会出现此类字段），
///   找不到即返回 nil，不编造。JSON 按 `_spdisplays_displayID` 与 CGDirectDisplayID 关联
///   （hex/decimal 双解释注册）。
public final class DisplayService: DisplayServiceProtocol {
    public init() {}

    public func listDisplays() async throws -> [DisplaySnapshot] {
        // system_profiler 子进程调用（~1-2s）与 CG 枚举都放 detached 上下文。
        await Task.detached(priority: .utility) {
            Self.readDisplays()
        }.value
    }

    // MARK: - 同步读取核心

    private static func readDisplays() -> [DisplaySnapshot] {
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        let err = CGGetOnlineDisplayList(UInt32(displayIDs.count), &displayIDs, &count)
        guard err == .success, count > 0 else { return [] }
        let onlineIDs = Array(displayIDs.prefix(Int(count)))

        let mainDisplayID = CGMainDisplayID()
        let profilerInfo = systemProfilerDisplayInfo()

        return onlineIDs.map { displayID -> DisplaySnapshot in
            var pixelWidth = 0
            var pixelHeight = 0
            var refreshRate: Double?
            if let mode = CGDisplayCopyDisplayMode(displayID) {
                pixelWidth = mode.pixelWidth
                pixelHeight = mode.pixelHeight
                let rate = mode.refreshRate
                refreshRate = rate > 0 ? rate : nil
            }
            let info = profilerInfo[displayID]
            return DisplaySnapshot(
                displayID: displayID,
                name: displayName(for: displayID, profilerName: info?.name),
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                refreshRateHz: refreshRate,
                linkRateLabel: info?.linkRate,
                isMain: displayID == mainDisplayID,
                isBuiltin: CGDisplayIsBuiltin(displayID) != 0,
                vendorNumber: nonSentinel(CGDisplayVendorNumber(displayID)),
                modelNumber: nonSentinel(CGDisplayModelNumber(displayID)),
                serialNumber: nonSentinel(CGDisplaySerialNumber(displayID))
            )
        }
        // 主屏排最前，其余按 displayID 稳定排序。
        .sorted { lhs, rhs in
            if lhs.isMain != rhs.isMain { return lhs.isMain }
            return lhs.displayID < rhs.displayID
        }
    }

    /// CGDisplay{Vendor,Model,Serial}Number 共用同一个"未知"哨兵值 0xFFFFFFFF
    /// （CGDirectDisplay.h：kDisplayVendorIDUnknown / kDisplayProductIDGeneric /
    /// kDisplaySerialNumberUnknown 均为该值），统一转 nil，不把哨兵值当真实身份参与匹配。
    private static func nonSentinel(_ value: UInt32) -> UInt32? {
        value == 0xFFFF_FFFF ? nil : value
    }

    /// 名称来源：NSScreen.localizedName（CGDisplayLocalizedName 的官方替代）→ system_profiler `_name`。
    private static func displayName(for displayID: CGDirectDisplayID, profilerName: String?) -> String? {
        for screen in NSScreen.screens {
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                .uint32Value, id == displayID else { continue }
            let name = screen.localizedName
            return name.isEmpty ? profilerName : name
        }
        return profilerName
    }

    private static func systemProfilerDisplayInfo() -> [CGDirectDisplayID: ProfilerDisplayInfo] {
        guard let output = runProcess("/usr/sbin/system_profiler", arguments: ["SPDisplaysDataType", "-json"]),
              let data = output.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return DisplayProfilerParsing.parse(root: root)
    }

    // MARK: - Process 辅助

    private static func runProcess(_ launchPath: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// system_profiler SPDisplaysDataType JSON 解析的补充信息（internal 便于单测）。
struct ProfilerDisplayInfo: Equatable {
    var name: String?
    var linkRate: String?
}

/// SPDisplaysDataType JSON 根字典 → displayID 补充信息映射的纯解析逻辑。
enum DisplayProfilerParsing {
    static func parse(root: [String: Any]) -> [CGDirectDisplayID: ProfilerDisplayInfo] {
        guard let gpus = root["SPDisplaysDataType"] as? [[String: Any]] else { return [:] }

        var result: [CGDirectDisplayID: ProfilerDisplayInfo] = [:]
        for gpu in gpus {
            guard let ndrvs = gpu["spdisplays_ndrvs"] as? [[String: Any]] else { continue }
            for ndrv in ndrvs {
                let info = ProfilerDisplayInfo(
                    name: ndrv["_name"] as? String,
                    linkRate: linkRateLabel(from: ndrv)
                )
                guard let idString = ndrv["_spdisplays_displayID"] as? String else { continue }
                register(idString: idString, info: info, into: &result)
            }
        }
        return result
    }

    /// 在单个显示器（ndrv）条目里查找键名含 "link" 的稳定字符串字段。
    /// 内置显示器没有该字段 → nil；不猜具体键名，也不对未知值做映射加工。
    static func linkRateLabel(from ndrv: [String: Any]) -> String? {
        for (key, value) in ndrv {
            let lowered = key.lowercased()
            guard lowered.contains("link"), !lowered.contains("displayid") else { continue }
            if let s = value as? String, !s.isEmpty {
                // 去掉 "spdisplays_" 前缀（如 "spdisplays_hbr3" → "hbr3"），保留系统原值语义。
                return s.hasPrefix("spdisplays_") ? String(s.dropFirst("spdisplays_".count)) : s
            }
        }
        return nil
    }

    /// displayID 字符串同时按 hex 与 decimal 解释注册（system_profiler 的进制未在文档中稳定约定）。
    static func register(idString: String, info: ProfilerDisplayInfo,
                         into dict: inout [CGDirectDisplayID: ProfilerDisplayInfo]) {
        let trimmed = idString.trimmingCharacters(in: .whitespaces)
        if let hex = UInt32(trimmed, radix: 16) {
            dict[hex] = info
        }
        if let dec = UInt32(trimmed, radix: 10) {
            dict[dec] = info
        }
    }
}
