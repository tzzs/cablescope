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

    // MARK: - 同步解析核心

    private static func readThunderboltDevices() -> [ThunderboltDeviceSnapshot] {
        guard let output = runProcess("/usr/sbin/system_profiler", arguments: ["SPThunderboltDataType", "-json"]),
              let data = output.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let buses = root["SPThunderboltDataType"] as? [[String: Any]] else {
            return []
        }

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
                collectDevices(in: receptacle, into: &devices)
            }
        }
        return devices.sorted { $0.name < $1.name }
    }

    /// 递归展平：字典节点带 `device_name_key` 即视为一台设备（链路中间的 switch/坞站也算）。
    private static func collectDevices(in node: [String: Any], into devices: inout [ThunderboltDeviceSnapshot]) {
        if let name = node["device_name_key"] as? String, !name.isEmpty {
            devices.append(ThunderboltDeviceSnapshot(
                name: name,
                vendorName: node["vendor_name_key"] as? String,
                linkSpeedLabel: (node["current_speed_key"] as? String) ?? (node["link_status_key"] as? String),
                deviceType: node["device_type_key"] as? String
            ))
        }
        for value in node.values {
            if let child = value as? [String: Any] {
                collectDevices(in: child, into: &devices)
            } else if let children = value as? [[String: Any]] {
                for child in children {
                    collectDevices(in: child, into: &devices)
                }
            }
        }
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
