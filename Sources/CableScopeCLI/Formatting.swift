import CableKit
import Darwin
import Foundation

// MARK: - 终端样式（仅在 stdout 为 TTY 时启用 ANSI，管道输出保持纯净）

enum Term {
    static let isTTY = isatty(STDOUT_FILENO) == 1

    static func bold(_ text: String) -> String {
        isTTY ? "\u{1B}[1m\(text)\u{1B}[0m" : text
    }

    static func dim(_ text: String) -> String {
        isTTY ? "\u{1B}[2m\(text)\u{1B}[0m" : text
    }
}

// MARK: - 数值 / 时间格式化

enum Fmt {
    static func watts(_ w: Double) -> String { String(format: "%.1f W", w) }

    static func volts(_ mV: Int) -> String { String(format: "%.1f V", Double(mV) / 1000) }

    static func amps(_ mA: Int) -> String { String(format: "%.2f A", Double(mA) / 1000) }

    /// 原始协商速率，如 "480 Mbps" / "10000 Mbps"
    static func rawMbps(_ bps: Int) -> String {
        let mbps = Double(bps) / 1_000_000
        let isInteger = mbps.truncatingRemainder(dividingBy: 1) == 0
        return String(format: isInteger ? "%.0f Mbps" : "%.1f Mbps", mbps)
    }

    /// "HH:mm:ss"，用于 watch 变化行
    static func clock(_ date: Date) -> String { timeString(date, format: "HH:mm:ss") }

    static func timeString(_ date: Date, format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        formatter.timeZone = .current
        return formatter.string(from: date)
    }
}

// MARK: - 展示辅助（只读扩展，不改动 CableKit）

extension USBDeviceSnapshot {
    var displayName: String { productName ?? vendorName ?? "未知设备" }

    /// VID 解析出的厂商名：优先用系统上报的 vendorName，缺失时查内置 VID 目录（M3）。
    var resolvedVendorName: String? {
        if let vendorName { return vendorName }
        guard let vendorID else { return nil }
        return VendorDirectory.shared.name(forVendorID: UInt32(vendorID))
    }

    var idDescription: String {
        var parts: [String] = []
        if let vendorID {
            var vidText = String(format: "VID 0x%04X", vendorID)
            // 目录里解析出厂商名时附在 hex 后，如 "VID 0x05F6 (iTE)"。
            if let name = resolvedVendorName {
                vidText += " (\(name))"
            }
            parts.append(vidText)
        }
        if let productID { parts.append(String(format: "PID 0x%04X", productID)) }
        return parts.joined(separator: " · ")
    }

    /// 如 "10000 Mbps → USB 3.x Gen2 10 Gbps"
    var speedDescription: String {
        guard let speed else { return "速率未知" }
        return "\(Fmt.rawMbps(speed.bitsPerSecond)) → \(speed.generation) \(speed.label)"
    }
}

extension DisplaySnapshot {
    var displayName: String { name ?? "显示器" }
}

extension PowerSnapshot {
    /// 一行摘要，如 "65.4 W · 充电中"；保温暂停时为 "已接通电源 · 未在充电"（瞬时功率为负，不展示）。
    var shortSummary: String {
        if isCharging, let watts {
            return "\(Fmt.watts(watts)) · 充电中"
        }
        if externalConnected {
            return "已接通电源 · 未在充电"
        }
        return "未接通电源"
    }
}

// MARK: - 错误类型

/// 运行期错误：stderr + 退出码 1
struct RuntimeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
