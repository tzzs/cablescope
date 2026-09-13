import Foundation

// MARK: - 子命令解析（手动解析，无第三方依赖）

enum ParsedCommand: Equatable {
    case snapshot(pretty: Bool)
    case pretty
    case watch(interval: Double)
    case rating(reset: Bool)
    case properties(className: String, json: Bool)
    case throughput(volume: String?, seconds: Double)
    case help
}

/// 用法错误：stderr + 退出码 2
struct UsageError: Error, CustomStringConvertible {
    let description: String

    static let hint = "运行 `swift run CableScopeCLI --help` 查看用法。"
}

enum Args {
    static let commandNames = ["snapshot", "pretty", "watch", "rating", "properties", "throughput"]

    static func parse(_ arguments: [String]) throws -> ParsedCommand {
        // --help / -h 出现在任意位置都显示帮助
        if arguments.contains("-h") || arguments.contains("--help") { return .help }

        // 无参数 → 默认 snapshot（紧凑 JSON）
        guard let command = arguments.first else { return .snapshot(pretty: false) }
        let flags = Array(arguments.dropFirst())

        switch command {
        case "snapshot":
            return .snapshot(pretty: try parseSnapshot(flags))
        case "pretty":
            try rejectFlags(flags, command: "pretty")
            return .pretty
        case "watch":
            return .watch(interval: try parseWatch(flags))
        case "rating":
            return .rating(reset: try parseRating(flags))
        case "properties":
            let parsed = try parseProperties(flags)
            return .properties(className: parsed.className, json: parsed.json)
        case "throughput":
            let parsed = try parseThroughput(flags)
            return .throughput(volume: parsed.volume, seconds: parsed.seconds)
        case "help":
            return .help
        default:
            throw UsageError(description: "未知命令「\(command)」，可用命令：\(commandNames.joined(separator: " / "))")
        }
    }

    /// properties [类名] [--json]：第一个非 `--` 开头参数为类名，缺省 IOUSBHostDevice。
    private static func parseProperties(_ flags: [String]) throws -> (className: String, json: Bool) {
        var className: String?
        var json = false
        for flag in flags {
            if flag == "--json" {
                json = true
            } else if flag.hasPrefix("--") {
                throw UsageError(description: "properties 不支持参数「\(flag)」")
            } else {
                guard className == nil else {
                    throw UsageError(description: "properties 只接受一个类名参数（额外收到「\(flag)」）")
                }
                className = flag
            }
        }
        return (className: className ?? CableScopeCLI.defaultRegistryClassName, json: json)
    }

    /// throughput [--volume <路径|卷名>] [--seconds N]：缺省自动选卷、每阶段 5 秒。
    private static func parseThroughput(_ flags: [String]) throws -> (volume: String?, seconds: Double) {
        var volume: String?
        var seconds = 5.0
        var index = 0
        while index < flags.count {
            let flag = flags[index]
            if flag == "--volume" {
                index += 1
                guard index < flags.count, !flags[index].hasPrefix("--"), !flags[index].isEmpty else {
                    throw UsageError(description: "--volume 需要一个挂载点路径或卷名")
                }
                volume = flags[index]
            } else if flag.hasPrefix("--volume=") {
                let value = String(flag.dropFirst("--volume=".count))
                guard !value.isEmpty, !value.hasPrefix("--") else {
                    throw UsageError(description: "--volume 需要一个挂载点路径或卷名")
                }
                volume = value
            } else if flag == "--seconds" {
                index += 1
                guard index < flags.count else {
                    throw UsageError(description: "--seconds 需要一个数值（单位：秒）")
                }
                seconds = try parseSeconds(flags[index])
            } else if flag.hasPrefix("--seconds=") {
                seconds = try parseSeconds(String(flag.dropFirst("--seconds=".count)))
            } else {
                throw UsageError(description: "throughput 不支持参数「\(flag)」")
            }
            index += 1
        }
        return (volume: volume, seconds: seconds)
    }

    private static func parseSeconds(_ text: String) throws -> Double {
        guard let value = Double(text), value > 0 else {
            throw UsageError(description: "--seconds 的值「\(text)」无效，需要大于 0 的秒数（允许小数）")
        }
        return value
    }

    private static func parseSnapshot(_ flags: [String]) throws -> Bool {
        var pretty = false
        for flag in flags {
            switch flag {
            case "--pretty": pretty = true
            default: throw UsageError(description: "snapshot 不支持参数「\(flag)」")
            }
        }
        return pretty
    }

    private static func rejectFlags(_ flags: [String], command: String) throws {
        if let first = flags.first {
            throw UsageError(description: "\(command) 不支持参数「\(first)」")
        }
    }

    private static func parseWatch(_ flags: [String]) throws -> Double {
        var interval = 2.0
        var index = 0
        while index < flags.count {
            let flag = flags[index]
            if flag == "--interval" {
                index += 1
                guard index < flags.count else {
                    throw UsageError(description: "--interval 需要一个数值（单位：秒）")
                }
                interval = try parseInterval(flags[index])
            } else if flag.hasPrefix("--interval=") {
                interval = try parseInterval(String(flag.dropFirst("--interval=".count)))
            } else {
                throw UsageError(description: "watch 不支持参数「\(flag)」")
            }
            index += 1
        }
        return interval
    }

    private static func parseInterval(_ text: String) throws -> Double {
        guard let value = Double(text), value > 0 else {
            throw UsageError(description: "--interval 的值「\(text)」无效，需要大于 0 的秒数")
        }
        return value
    }

    private static func parseRating(_ flags: [String]) throws -> Bool {
        var reset = false
        for flag in flags {
            switch flag {
            case "--reset": reset = true
            default: throw UsageError(description: "rating 不支持参数「\(flag)」")
            }
        }
        return reset
    }
}
