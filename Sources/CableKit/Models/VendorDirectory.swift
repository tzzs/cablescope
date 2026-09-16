import Foundation

// MARK: - VID → 厂商名目录（M3）
//
// 数据来自仓库内置的 `usb-vendors.json`（USB-IF 厂商列表 + usb.ids 的精选子集，
// 常见 USB-C / 坞站 / hub / 存储厂商；欢迎 PR 扩充条目）。
// 目录是只读映射，查找失败（未收录）返回 nil，由调用方决定回退展示（通常是 hex）。

/// USB VID → 厂商名的只读查询表。
///
/// - `shared`：懒加载 bundle 内置的 `usb-vendors.json`；资源缺失或解析失败时回退空表，永不崩溃。
/// - 测试可用 `init(entries:)`（internal）注入自定义映射，不依赖 bundle 资源。
public struct VendorDirectory: Sendable {
    /// 共享实例：随包内置的厂商库。
    public static let shared: VendorDirectory = {
        guard let data = Self.loadBundledJSON() else {
            // Bundle 资源不可用（例如打包配置遗漏）：回退空表，宁缺毋崩。
            return VendorDirectory(entries: [:])
        }
        return VendorDirectory(entries: Self.parse(data))
    }()

    /// 安全定位随包 `usb-vendors.json`。
    ///
    /// 不复用 SwiftPM 自动生成的 `Bundle.module`：那个访问器在资源 bundle **整体缺失**
    /// （而非 bundle 内某个文件缺失）时会执行自带的 `fatalError`——直接终止进程，
    /// 早于任何调用方的 guard/try? 生效，因此无法被 `shared` 上面这层防护接住
    /// （2026-09 一次未妥善打包的 .app 在真实设备上复现过此崩溃）。候选路径探测逻辑
    /// 与 `KitLocalization`（本地化资源）共用同一份实现，见 `CableKitResourceBundle`。
    static func loadBundledJSON(
        bundleFileName: String = "CableScope_CableKit.bundle",
        candidates: [URL?] = [
            Bundle.main.resourceURL,
            Bundle(for: BundleAnchor.self).resourceURL,
            Bundle.main.bundleURL,
        ]
    ) -> Data? {
        guard let bundle = CableKitResourceBundle.probe(bundleFileName: bundleFileName, candidates: candidates),
              let resourceURL = bundle.url(forResource: "usb-vendors", withExtension: "json"),
              let data = try? Data(contentsOf: resourceURL) else { return nil }
        return data
    }

    /// VID（16 位 USB 厂商 ID）→ 厂商名。
    private let entries: [UInt32: String]

    /// 注入式初始化（internal）：测试可传入自定义映射。
    init(entries: [UInt32: String]) {
        self.entries = entries
    }

    /// 查询厂商名；未收录的 VID 返回 nil。
    public func name(forVendorID vendorID: UInt32) -> String? {
        entries[vendorID]
    }

    /// 已收录的厂商条目数。
    public var knownCount: Int { entries.count }

    // MARK: JSON 解析

    /// 解析 `usb-vendors.json` 数据为 [VID: 厂商名]。
    /// - vid 为 hex 字符串（如 "05AC"），用 `UInt32(_, radix: 16)` 转换，非法条目跳过；
    /// - 结构不符 / 解析失败返回空表。
    static func parse(_ data: Data) -> [UInt32: String] {
        struct Payload: Decodable {
            struct Entry: Decodable {
                let vid: String
                let name: String
            }
            let vendors: [Entry]
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return [:] }
        var result: [UInt32: String] = [:]
        for entry in payload.vendors {
            guard let vid = UInt32(entry.vid, radix: 16) else { continue }
            result[vid] = entry.name
        }
        return result
    }
}

/// `Bundle(for:)` 的锚点类：借助其所在 bundle 参与候选路径查找，
/// 用法等价于 SwiftPM 生成访问器里的私有 `BundleFinder`。
private final class BundleAnchor {}
