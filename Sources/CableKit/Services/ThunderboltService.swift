import Foundation

/// 雷电/USB4 设备（`system_profiler SPThunderboltDataType -json` 适配）。
///
/// 本机实测 JSON 结构（macOS 26，Apple Silicon）：
/// ```
/// SPThunderboltDataType: [
///   { _name: "thunderboltusb4_bus_1", device_name_key: "MacBook Air", vendor_name_key: "Apple Inc.",
///     receptacle_1_tag: { current_speed_key: "Up to 40 Gb/s",
///                         receptacle_status_key: "receptacle_no_devices_connected", ... } }
/// ]
/// ```
/// - 顶层 bus 条目是**本机主控**（device_name_key = "MacBook Air"），不算外接设备。
/// - 外接设备挂在 `receptacle_N_tag` 下，树形可级联（雷电链/坞站），需**递归展平**：
///   收集 receptacle 子树中所有带 `device_name_key` 的节点。
/// - `receptacle_status_key == "receptacle_no_devices_connected"` 的 receptacle 无设备；
///   全部为空时返回空数组（当前无雷电外设的场景已实测）。
public final class ThunderboltService: ThunderboltServiceProtocol {
    public init() {}

    public func listThunderboltDevices() async throws -> [ThunderboltDeviceSnapshot] {
        await Task.detached(priority: .utility) {
            Self.readThunderboltDevices()
        }.value
    }

    // MARK: - 同步读取核心

    private static func readThunderboltDevices() -> [ThunderboltDeviceSnapshot] {
        guard let output = runProcess("/usr/sbin/system_profiler", arguments: ["SPThunderboltDataType", "-json"]),
              let data = output.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        return ThunderboltParsing.parse(root: root)
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

/// 雷雳代际识别（M3）：由链路速度标签反推代际的纯函数（internal 便于单测）。
///
/// 依据（真机实测，macOS 26 / M4 空载）：system_profiler 的 `current_speed_key`
/// 形如 "Up to 40 Gb/s"（也兼容无空格的 "Up to 40Gb/s" 形态）。速度上限是最稳定的代际信号：
/// - 120Gb/s → 雷雳 5（非对称模式）
/// - 80Gb/s → 雷雳 5
/// - 40Gb/s → 雷雳 4 / USB4（同速可跨代际，措辞并列为诚实表述）
/// - 20/22Gb/s → 雷雳 3
/// - 其他/缺失 → nil（不猜测）
///
/// M6 修复：实现为提取标签中的最大数值再匹配——旧 contains 子串匹配会把
/// 雷雳 5 非对称标签 "Up to 120 Gb/s" 的 "20" 误判为雷雳 3；顺带让 "0x140"
/// 这类十六进制状态码（link_status_key 兜底形态）不再被误读成速度。
/// 真机实测仅见过 40Gb/s 形态，120G 非对称标签待有雷雳 5 外设时复核。
/// 增强路径结论（真机实测）：system_profiler JSON 无 firmware/retimer 类代际字段
/// （`link_status_key` 是 "0x100" 形态的十六进制状态码）；ioreg `IOThunderboltPort`
/// 虽有 `"Thunderbolt Version" = 32` 字段，但其取值语义无法在无外设时验证，故不纳入映射。
enum ThunderboltGeneration {
    static func label(forLinkSpeedLabel label: String?) -> String? {
        let gbps = label?.split(whereSeparator: { !$0.isNumber })
            .compactMap { Int($0) }
            .max()
        switch gbps {
        case 120, 80: return "雷雳 5"
        case 40: return "雷雳 4 / USB4"
        case 20, 22: return "雷雳 3"
        default: return nil
        }
    }
}

/// SPThunderboltDataType JSON 根字典 → 设备列表的纯解析逻辑（internal 便于单测，无进程依赖）。
enum ThunderboltParsing {
    static func parse(root: [String: Any]) -> [ThunderboltDeviceSnapshot] {
        guard let buses = root["SPThunderboltDataType"] as? [[String: Any]] else { return [] }

        var devices: [ThunderboltDeviceSnapshot] = []
        for bus in buses {
            for (key, value) in bus {
                // receptacle_N_tag（N 为端口号）
                guard key.hasPrefix("receptacle_"), key.hasSuffix("_tag"),
                      let receptacle = value as? [String: Any] else { continue }
                // 仅在系统明确报告"无设备连接"时跳过；status 缺失时仍尝试收集（保守不漏报）。
                if let status = receptacle["receptacle_status_key"] as? String,
                   status == "receptacle_no_devices_connected" {
                    continue
                }
                // 端口号随设备保留（PortGrouping 以它聚合成雷雳会话）；编号非数字时为 nil。
                let number = key.dropFirst("receptacle_".count).dropLast("_tag".count)
                collectDevices(in: receptacle, receptaclePort: Int(number), depth: 0, into: &devices)
            }
        }
        return devices.sorted { $0.name < $1.name }
    }

    /// 递归展平：字典节点带 `device_name_key` 即视为一台设备（链路中间的 switch/坞站也算）。
    /// 整条 receptacle 子树（含级联链/坞站下游）共享同一个端口号；
    /// `depth` 为 JSON 嵌套层级（每层 dict/array +1），receptacle 根设备为 0（M6 拓扑深度）。
    static func collectDevices(in node: [String: Any], receptaclePort: Int?, depth: Int,
                               into devices: inout [ThunderboltDeviceSnapshot]) {
        if let name = node["device_name_key"] as? String, !name.isEmpty {
            // 代际由速度标签反推（映射规则见 ThunderboltGeneration 注释）
            let linkSpeed = (node["current_speed_key"] as? String) ?? (node["link_status_key"] as? String)
            devices.append(ThunderboltDeviceSnapshot(
                name: name,
                vendorName: node["vendor_name_key"] as? String,
                linkSpeedLabel: linkSpeed,
                deviceType: node["device_type_key"] as? String,
                receptaclePort: receptaclePort,
                generation: ThunderboltGeneration.label(forLinkSpeedLabel: linkSpeed),
                depth: depth
            ))
        }
        for value in node.values {
            if let child = value as? [String: Any] {
                collectDevices(in: child, receptaclePort: receptaclePort, depth: depth + 1, into: &devices)
            } else if let children = value as? [[String: Any]] {
                for child in children {
                    collectDevices(in: child, receptaclePort: receptaclePort, depth: depth + 1, into: &devices)
                }
            }
        }
    }
}
