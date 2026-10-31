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
public final class DisplayService: DisplayServiceProtocol, @unchecked Sendable {
    /// `system_profiler` 结果的缓存：key 是在线显示器 ID 集合（纯 CG 调用，无子进程），
    /// 插拔显示器时 key 立即变化 → 立即重读；没插拔时一直命中，子进程不再每轮重启。
    /// TTL 是「显示器没插拔但链路参数可能变了」（如切换分辨率影响 DP 链路速率）的兜底上限。
    /// 线程安全由 TTLCache 自身保证，故整类标 `@unchecked Sendable`。
    private let profilerCache: TTLCache<Set<CGDirectDisplayID>, [CGDirectDisplayID: ProfilerDisplayInfo]>

    /// - Parameter profilerCacheTTL: `system_profiler` 结果的缓存上限（秒），`<= 0` 关闭缓存。
    public init(profilerCacheTTL: TimeInterval = 30) {
        self.profilerCache = TTLCache(ttl: profilerCacheTTL)
    }

    public func listDisplays() async -> [DisplaySnapshot] {
        // system_profiler 子进程调用与 CG 枚举都放 detached 上下文。
        let cache = profilerCache
        return await Task.detached(priority: .utility) {
            Self.readDisplays(profilerCache: cache)
        }.value
    }

    // MARK: - 同步读取核心

    /// 枚举当前在线的显示器 ID。
    ///
    /// `CGGetOnlineDisplayList(maxDisplays, &displayIDs, &count)` 的 `maxDisplays` 是
    /// **入参上限**：头文件写明 "no more than `maxDisplays` will be stored"，即
    /// `count` 恒 ≤ `maxDisplays`。因此当在线显示器数超过缓冲区时，返回的 `count`
    /// 会被截断到上限，多出来的显示器静默消失（固定 16 的缓冲曾让多屏工作站少报屏幕）。
    ///
    /// 正确做法是**自己按倍增扩大缓冲**重试：注意不能用 `count` 来决定新容量——
    /// `count` 恒 ≤ 旧容量，用它赋值等于原地踏步，循环永不退出（整机挂死）。
    /// 扩容策略抽成纯函数 `nextCapacity(capacity:maxCapacity:)` 以便单测。
    private static func onlineDisplayIDs() -> [CGDirectDisplayID] {
        let initialCapacity: UInt32 = 16
        let maxCapacity: UInt32 = 64

        var capacity = initialCapacity
        while true {
            var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(capacity))
            var count: UInt32 = 0
            let err = CGGetOnlineDisplayList(capacity, &displayIDs, &count)
            guard err == .success else { return [] }

            // 装满即可能被截断：扩大缓冲后重试。
            guard count >= capacity else {
                return Array(displayIDs.prefix(Int(count)))
            }
            guard let next = nextCapacity(capacity: capacity, maxCapacity: maxCapacity) else {
                // 已达上限仍装不下：CoreGraphics 返回了异常数据，就用已知的那部分。
                return Array(displayIDs.prefix(Int(capacity)))
            }
            capacity = next
        }
    }

    /// 显示器缓冲的扩容策略（纯函数，便于单测）。
    ///
    /// - Parameters:
    ///   - count: 上一轮 `CGGetOnlineDisplayList` 返回的个数（恒 ≤ capacity）。
    ///   - capacity: 上一轮的缓冲区容量。
    ///   - maxCapacity: 扩容上限。
    /// - Returns: 下一轮的容量；返回 nil 表示已达上限、不再扩容。
    ///
    /// 关键点：新容量由**旧容量**倍增得到。这里**刻意不接受 `count` 参数**——
    /// `count` 恒 ≤ `capacity`（CoreGraphics 头文件："no more than maxDisplays will be
    /// stored"），拿它决定新容量就是恒等赋值，循环永不收敛、整机挂死。
    /// 把这个陷阱写进接口本身（而不是只写在注释里），是为了让"顺手用 count"这个
    /// 错误用法在编译期就无从下手。
    static func nextCapacity(capacity: UInt32, maxCapacity: UInt32) -> UInt32? {
        guard capacity < maxCapacity else { return nil }
        return min(capacity * 2, maxCapacity)
    }

    private static func readDisplays(
        profilerCache: TTLCache<Set<CGDirectDisplayID>, [CGDirectDisplayID: ProfilerDisplayInfo]>
    ) -> [DisplaySnapshot] {
        let onlineIDs = onlineDisplayIDs()
        guard !onlineIDs.isEmpty else { return [] }

        let mainDisplayID = CGMainDisplayID()
        let profilerInfo = profilerCache.value(for: Set(onlineIDs)) { systemProfilerDisplayInfo() }

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
    ///
    /// 只负责「收集候选」，选哪一个交给纯函数 `DisplayNameSelection`（便于单测）。
    private static func displayName(for displayID: CGDirectDisplayID, profilerName: String?) -> String? {
        let screens: [DisplayNameSelection.ScreenCandidate] = NSScreen.screens.compactMap { screen in
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                .uint32Value else { return nil }
            return DisplayNameSelection.ScreenCandidate(displayID: id, name: screen.localizedName)
        }
        return DisplayNameSelection.select(screens: screens, displayID: displayID, profilerName: profilerName)
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
        Subprocess.run(launchPath, arguments: arguments)
    }
}

/// 显示器名称的候选选择（纯逻辑，便于单测）。
///
/// 名称来源优先级：`NSScreen.localizedName`（系统给出的本地化名）→ system_profiler 的 `_name`。
/// 系统给出的名字**不是我们的文案**：它跟随系统的 Language & Region，不随 App 内语言切换
/// （见 AGENTS.md「Localization」），外部显示器的 EDID 产品名也是厂商专有名词。因此这里
/// 只负责「选哪一个」，不做任何翻译或改写。
enum DisplayNameSelection {
    /// 一台屏幕的候选名：`CGDirectDisplayID` + 系统本地化名。
    struct ScreenCandidate: Equatable {
        let displayID: CGDirectDisplayID
        let name: String
    }

    /// 在候选屏幕里找 `displayID` 对应的那台，返回应展示的名字。
    ///
    /// - 找到匹配屏幕：系统名非空 → 用系统名；系统名为空 → 回退 system_profiler 名字。
    /// - 没有匹配屏幕（屏幕已拔出，或该显示器没有对应的 NSScreen）→ 用 system_profiler 名字。
    /// - 两者都没有 → nil（调用方据此显示"未命名"）。
    static func select(screens: [ScreenCandidate],
                       displayID: CGDirectDisplayID,
                       profilerName: String?) -> String? {
        for screen in screens where screen.displayID == displayID {
            return screen.name.isEmpty ? profilerName : screen.name
        }
        return profilerName
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
    ///
    /// 键按**字典序**遍历而非 `Dictionary` 的原生顺序：`[String: Any]` 的迭代顺序取决于
    /// 哈希种子，同一份输入在不同进程里可能给出不同的结果（"LinkRate" 与
    /// "LinkRateMinimum" 同时存在时命中哪个不确定）——那会让同一次插拔在两次运行里
    /// 报出不同的链路速率。字典序让结果稳定、可复现、可写断言。
    static func linkRateLabel(from ndrv: [String: Any]) -> String? {
        for key in ndrv.keys.sorted() {
            let lowered = key.lowercased()
            guard lowered.contains("link"), !lowered.contains("displayid") else { continue }
            if let s = ndrv[key] as? String, !s.isEmpty {
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
