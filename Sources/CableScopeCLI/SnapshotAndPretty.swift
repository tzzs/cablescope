import CableKit
import Foundation

// MARK: - snapshot 子命令：采集一次快照，输出 JSON（默认紧凑，--pretty 美化）

extension CableScopeCLI {
    static func runSnapshot(pretty: Bool) async throws {
        let snapshot = try await acquireSnapshot()
        let data: Data
        do {
            data = try snapshot.toJSON(pretty: pretty)
        } catch {
            throw RuntimeError("JSON 编码失败：\(error)")
        }
        print(String(data: data, encoding: .utf8) ?? "{}")
    }
}

// MARK: - pretty 子命令：人类可读输出

extension CableScopeCLI {
    static func runPretty() async throws {
        let snapshot = try await acquireSnapshot()
        print(render(snapshot))
    }

    static func render(_ snapshot: CableSnapshot) -> String {
        var lines: [String] = []
        let rule = String(repeating: "─", count: 32)

        lines.append("CableScope · 线缆透视")
        lines.append(rule)
        lines.append("")
        lines.append("⚡ 电源")
        lines.append(powerSection(snapshot.power))
        lines.append("")
        lines.append("🔌 USB")
        lines.append(usbSection(snapshot.usbDevices))
        lines.append("")
        lines.append("🖥 显示器")
        lines.append(displaySection(snapshot.displays))
        lines.append("")
        lines.append("⚡ 雷电")
        lines.append(thunderboltSection(snapshot.thunderboltDevices))
        lines.append("")
        lines.append(rule)
        lines.append(Term.dim("\(Fmt.timeString(snapshot.timestamp, format: "yyyy-MM-dd HH:mm:ss")) · 线缆规格基于协商结果推断，仅供参考"))
        return lines.joined(separator: "\n")
    }

    private static func powerSection(_ power: PowerSnapshot?) -> String {
        guard let power else { return "  暂无数据" }

        var lines: [String] = []
        var headline = power.isCharging ? "充电中" : "未在充电"
        if let watts = power.watts ?? power.pdContract?.watts {
            headline += "  " + Term.bold(Fmt.watts(watts))
        }
        lines.append("  " + headline)

        if let voltage = power.adapterVoltageMV, let amperage = power.adapterAmperageMA {
            lines.append("  电压/电流  \(Fmt.volts(voltage)) / \(Fmt.amps(amperage))")
        } else if let contract = power.pdContract {
            lines.append("  电压/电流  \(Fmt.volts(contract.voltageMV)) / \(Fmt.amps(contract.currentMA))")
        }

        if let contract = power.pdContract {
            var pd = "PD 合同  \(Fmt.volts(contract.voltageMV)) × \(Fmt.amps(contract.currentMA))"
            if contract.implies5ACable { pd += "（5A e-marker 线）" }
            lines.append("  " + pd)
        }

        if let percent = power.batteryPercent {
            lines.append("  电量  \(Int(percent.rounded()))%")
        }
        if let cycleCount = power.cycleCount {
            lines.append("  电池循环  \(cycleCount) 次")
        }
        if let adapter = power.adapterDescription, !adapter.isEmpty {
            lines.append("  适配器  \(adapter)")
        }
        return lines.joined(separator: "\n")
    }

    private static func usbSection(_ devices: [USBDeviceSnapshot]) -> String {
        if devices.isEmpty { return "  未检测到 USB 设备" }
        return devices.map { device in
            var parts = [device.speedDescription]
            let ids = device.idDescription
            if !ids.isEmpty { parts.append(ids) }
            return "  • \(device.displayName)  " + parts.joined(separator: " · ")
        }
        .joined(separator: "\n")
    }

    private static func displaySection(_ displays: [DisplaySnapshot]) -> String {
        if displays.isEmpty { return "  未检测到显示器" }
        return displays.map { display in
            var parts = [display.resolutionLabel]
            if let hz = display.refreshRateHz {
                parts.append(String(format: "%.0f Hz", hz))
            }
            if let link = display.linkRateLabel {
                parts.append("链路 \(link)")
            }
            if display.isMain { parts.append("主显示器") }
            return "  • \(display.displayName)  " + parts.joined(separator: " · ")
        }
        .joined(separator: "\n")
    }

    private static func thunderboltSection(_ devices: [ThunderboltDeviceSnapshot]) -> String {
        if devices.isEmpty { return "  未检测到雷电设备" }
        return devices.map { device in
            var parts: [String] = []
            if let vendor = device.vendorName { parts.append(vendor) }
            if let link = device.linkSpeedLabel { parts.append(link) }
            if let type = device.deviceType { parts.append(type) }
            let suffix = parts.isEmpty ? "" : "  " + parts.joined(separator: " · ")
            return "  • \(device.name)\(suffix)"
        }
        .joined(separator: "\n")
    }
}
