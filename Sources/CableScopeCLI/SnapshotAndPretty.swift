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
        lines.append(powerSection(snapshot.power, ports: snapshot.ports))
        lines.append("")
        lines.append("🔌 线缆端口 (\(snapshot.sessions.count))")
        lines.append(sessionsSection(snapshot.sessions, ports: snapshot.ports))
        lines.append("")
        lines.append("🖥 显示器")
        lines.append(displaySection(snapshot.displays))
        lines.append("")
        lines.append(rule)
        lines.append(Term.dim("\(Fmt.timeString(snapshot.timestamp, format: "yyyy-MM-dd HH:mm:ss")) · 线缆规格基于协商结果推断，仅供参考"))
        return lines.joined(separator: "\n")
    }

    private static func powerSection(_ power: PowerSnapshot?, ports: [USBCPortSnapshot]) -> String {
        guard let power else { return "  暂无数据" }

        var lines: [String] = []
        // 标题数字的取舍：充电中显示瞬时功率；已接通但未充电（保温/优化充电暂停，
        // 电池侧电流为负）时瞬时功率无意义，显示 PD 合同能力；未接通时不显示数字。
        let headline: String
        if power.isCharging {
            headline = "充电中" + wattsSuffix(power.watts)
        } else if power.externalConnected {
            headline = "已接通电源（未在充电）" + wattsSuffix(power.pdContract?.watts)
        } else {
            headline = "未接通电源（使用电池）"
        }
        lines.append("  " + Term.bold(headline))

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

        // PD 档位表（端口控制器直读）：一行列出全部档位，当前协商档加 * 标记。
        if let pdo = pdoSource(from: ports), !pdo.options.isEmpty {
            let winningIndex = pdo.winningIndex
            let options = pdo.options.enumerated().map { index, phase in
                index == winningIndex ? Term.bold("*\(phase.label)") : phase.label
            }
            lines.append("  PD 档位  " + options.joined(separator: " · "))
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

    /// 展示用的 PD 档位来源：优先正在协商的端口，否则档位最多的一份。
    private static func pdoSource(from ports: [USBCPortSnapshot]) -> PDOPortPowerSnapshot? {
        let sources = ports.compactMap(\.powerSource)
        return sources.first { $0.winning != nil }
            ?? sources.max { $0.options.count < $1.options.count }
    }

    /// 功率后缀："  100.0 W"；nil 时为空串。
    private static func wattsSuffix(_ watts: Double?) -> String {
        guard let watts else { return "" }
        return "  " + Term.bold(Fmt.watts(watts))
    }

    /// 按物理端口分组输出设备（会话由 PortGrouping 在采集时聚合，hub 下行设备逐级缩进）。
    private static func sessionsSection(_ sessions: [CableSession], ports: [USBCPortSnapshot]) -> String {
        guard !sessions.isEmpty else { return "  未检测到线缆 / 设备" }
        let portsByID = Dictionary(ports.map { ($0.portID, $0) }, uniquingKeysWith: { first, _ in first })
        return sessions.map { session in
            var lines = ["  ▸ \(session.portLabel)  " + Term.dim("[\(session.id)]")]

            if let port = session.physicalPortID.flatMap({ portsByID[$0] }),
               let status = portStatusLine(port) {
                lines.append("    \(status)")
            }

            for device in session.usbDevices {
                let depth = PortGrouping.hubDepth(forLocationID: device.locationID)
                let indent = String(repeating: "  ", count: depth + 1)
                var parts = [device.speedDescription]
                let ids = device.idDescription
                if !ids.isEmpty { parts.append(ids) }
                lines.append("\(indent)• \(device.displayName)  " + parts.joined(separator: " · "))
            }
            for device in session.thunderboltDevices {
                // 拓扑深度缩进（M6）：与 USB 设备链同一 indent 模式
                let indent = String(repeating: "  ", count: (device.depth ?? 0) + 1)
                var parts: [String] = []
                if let vendor = device.vendorName { parts.append(vendor) }
                if let link = device.linkSpeedLabel { parts.append(link) }
                // 雷雳代际（M3）：存在时显示，如 "· 雷雳 4 / USB4"
                if let generation = device.generation { parts.append(generation) }
                let suffix = parts.isEmpty ? "" : "  " + parts.joined(separator: " · ")
                lines.append("\(indent)• \(device.name)\(suffix)")
            }
            if session.deviceCount == 0 {
                lines.append("    （无设备）")
            }
            return lines.joined(separator: "\n")
        }
        .joined(separator: "\n")
    }

    /// 端口控制器状态行：形态/方向 + e-marker + USB4 能力。无可说内容返回 nil。
    private static func portStatusLine(_ port: USBCPortSnapshot) -> String? {
        var parts: [String] = []
        if let portType = port.portType { parts.append(portType) }
        if let orientation = port.plugOrientation {
            parts.append(orientation == 1 ? "正向" : "反向")
        }
        if let eMarker = port.eMarker {
            if let description = eMarker.productTypeDescription {
                parts.append(DiagnosticsEngine.eMarkerDescription(description))
            }
            if let rating = eMarker.decodedCurrentRating, rating != .reserved {
                parts.append(rating.label)
            }
        }
        if port.supportsThunderboltUSB4 { parts.append("USB4/雷雳可用") }
        guard !parts.isEmpty else { return nil }
        return Term.dim("端口：") + parts.joined(separator: " · ")
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
}
