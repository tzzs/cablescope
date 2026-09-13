import CoreFoundation
import Foundation

// MARK: - IORegistry 属性值的通用表示
//
// `IORegistryEntryCreateCFProperties` 返回的属性字典值类型不可预知（标量/字符串/布尔/
// 二进制/日期/嵌套数组与字典），无法直接用 Codable 结构承载。IORegistryValue 用递归
// enum 无损表示任意 CF 属性树，是 CLI / App 展示「全量 IOKit 属性」的数据契约：
// - Codable + Sendable + Hashable：可随快照序列化、跨 actor 传递、参与变化检测；
// - `displayText` 提供与 ioreg 习惯一致的文本渲染（布尔 Yes/No、Data 十六进制）。

public indirect enum IORegistryValue: Codable, Hashable, Sendable {
    case string(String)
    /// 整型数值（CFNumber 非浮点）
    case number(Int64)
    /// 浮点数值（CFNumber 浮点类型）
    case double(Double)
    case boolean(Bool)
    /// 二进制属性（如 EDID），保留原始字节
    case data(Data)
    case date(Date)
    case array([IORegistryValue])
    case dictionary([String: IORegistryValue])
    /// 其他无法识别的 CF 类型，降级为文本描述（不丢键，只降值）
    case other(String)

    // MARK: CF/Any → IORegistryValue

    /// 按真实 CF 类型分派（不能依赖 Swift `as?` 的 NSNumber 桥接顺序——NSNumber 会同时
    /// 成功桥接到 Bool/Int/Double，必须用 CFTypeID 精确区分布尔与数值）。
    public init(anyValue: Any) {
        let cfValue = anyValue as CFTypeRef?
        switch cfValue {
        case let value as String:
            self = .string(value)
        case let value as NSNumber where CFGetTypeID(value) == CFBooleanGetTypeID():
            self = .boolean(value.boolValue)
        case let value as NSNumber where CFGetTypeID(value) == CFNumberGetTypeID():
            // CFNumberIsFloatType 区分整型与浮点，避免 20.5 被截断成 20。
            if CFNumberIsFloatType(value) {
                self = .double(value.doubleValue)
            } else {
                self = .number(value.int64Value)
            }
        case let value as Data:
            self = .data(value)
        case let value as Date:
            self = .date(value)
        case let value as [Any]:
            self = .array(value.map { IORegistryValue(anyValue: $0) })
        case let value as [String: Any]:
            var converted: [String: IORegistryValue] = [:]
            converted.reserveCapacity(value.count)
            for (key, element) in value {
                converted[key] = IORegistryValue(anyValue: element)
            }
            self = .dictionary(converted)
        default:
            self = .other(String(describing: anyValue))
        }
    }

    /// 批量转换属性字典。
    public static func dictionary(from properties: [String: Any]) -> [String: IORegistryValue] {
        var result: [String: IORegistryValue] = [:]
        result.reserveCapacity(properties.count)
        for (key, value) in properties {
            result[key] = IORegistryValue(anyValue: value)
        }
        return result
    }

    // MARK: 渲染

    /// 人类可读单行文本（与 ioreg 习惯一致：布尔 Yes/No、Data 十六进制）。
    public var displayText: String {
        switch self {
        case .string(let value): return value
        case .number(let value): return String(value)
        case .double(let value): return Self.doubleText(value)
        case .boolean(let value): return value ? "Yes" : "No"
        case .data(let value): return value.displayAsHex(limit: Self.dataHexLimit)
        case .date(let value): return Self.dateFormatter.string(from: value)
        case .array(let values):
            return "[" + values.map(\.displayText).joined(separator: ", ") + "]"
        case .dictionary(let dict):
            let entries = Self.sortedKeys(in: dict)
                .map { "\($0)=\(dict[$0]?.displayText ?? "")" }
            return "{" + entries.joined(separator: ", ") + "}"
        case .other(let value): return value
        }
    }

    /// Data 渲染上限（字节）：完整十六进制太长，超出部分省略并标注总长。
    static let dataHexLimit = 64

    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func doubleText(_ value: Double) -> String {
        guard value.isFinite else { return String(describing: value) }
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int64(value))
        }
        return String(value)
    }

    /// 字典稳定展示顺序：键名字典序。
    public static func sortedKeys(in dict: [String: IORegistryValue]) -> [String] {
        dict.keys.sorted()
    }
}

// MARK: - Codable：JSON 平铺编码（镜像 registry 的自然结构，便于脚本消费）
//
// 标量直接编码为 JSON 标量（string/number/boolean），数组与字典递归平铺——
// 即 `properties --json` / `snapshot` 输出的 JSON 与 ioreg 的树形结构一一对应，
// 而不是 Swift 默认的 tagged enum 包装（"number": {"_0": 2}）。
// 保真边界（JSON 无法表达时的降级，均在文档承诺内）：
// - .data 编码为 base64 字符串，解码时按普通字符串还原（类型不回环）；
// - .date 编码为 ISO8601 字符串，解码为 .string；
// - .double 整数值（JSON 无 int/float 之分）解码后为 .number；
// - .other 编码为其文本描述。

extension IORegistryValue {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Bool 必须先于数值判定：JSON 的 true/false 不能被解释成 1/0。
        if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .number(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([IORegistryValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: IORegistryValue].self) {
            self = .dictionary(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container,
                                                   debugDescription: "不支持的 JSON 值类型（IORegistryValue）")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .boolean(let value): try container.encode(value)
        case .data(let value): try container.encode(value.base64EncodedString())
        case .date(let value): try container.encode(Self.dateFormatter.string(from: value))
        case .array(let value): try container.encode(value)
        case .dictionary(let value): try container.encode(value)
        case .other(let value): try container.encode(value)
        }
    }
}

// MARK: - 十六进制渲染

extension Data {
    /// `0x01 0x02 … (N bytes)`；超出 limit 字节省略并标注。
    func displayAsHex(limit: Int) -> String {
        guard !isEmpty else { return "<empty data>" }
        let bytes = [UInt8](self)
        let shown = bytes.prefix(limit)
        let hex = shown.map { String(format: "0x%02x", $0) }.joined(separator: " ")
        if bytes.count > limit {
            return "\(hex) … (\(bytes.count) bytes)"
        }
        return hex
    }
}

// MARK: - 属性树文本渲染（CLI / App「拷贝全部」共用）

public enum RegistryText {
    /// 多行缩进渲染属性字典（键名字典序，嵌套字典/数组递归缩进）。
    public static func render(_ properties: [String: IORegistryValue], indent: String = "  ") -> [String] {
        renderDictionary(properties, level: 0, indent: indent)
    }

    /// 渲染单条 registry 条目的全部属性为可直接拷贝的文本块。
    public static func render(entry: RegistryEntrySnapshot) -> String {
        var lines: [String] = []
        var header = entry.name ?? entry.className
        if let name = entry.name, name != entry.className {
            header += " (\(entry.className))"
        }
        lines.append("# \(header) [registryID: \(entry.registryID)]")
        lines.append(contentsOf: render(entry.properties))
        return lines.joined(separator: "\n")
    }

    private static func renderDictionary(_ dict: [String: IORegistryValue],
                                         level: Int,
                                         indent: String) -> [String] {
        var lines: [String] = []
        for key in IORegistryValue.sortedKeys(in: dict) {
            guard let value = dict[key] else { continue }
            switch value {
            case .dictionary(let nested):
                if nested.isEmpty {
                    lines.append("\(String(repeating: indent, count: level))\(key): {}")
                } else {
                    lines.append("\(String(repeating: indent, count: level))\(key):")
                    lines.append(contentsOf: renderDictionary(nested, level: level + 1, indent: indent))
                }
            case .array(let items):
                lines.append("\(String(repeating: indent, count: level))\(key):")
                lines.append(contentsOf: renderArray(items, level: level + 1, indent: indent))
            default:
                lines.append("\(String(repeating: indent, count: level))\(key): \(value.displayText)")
            }
        }
        return lines
    }

    private static func renderArray(_ items: [IORegistryValue], level: Int, indent: String) -> [String] {
        var lines: [String] = []
        for (_, item) in items.enumerated() {
            switch item {
            case .dictionary(let nested):
                if nested.isEmpty {
                    lines.append("\(String(repeating: indent, count: level))- {}")
                } else {
                    lines.append("\(String(repeating: indent, count: level))-")
                    lines.append(contentsOf: renderDictionary(nested, level: level + 1, indent: indent))
                }
            default:
                lines.append("\(String(repeating: indent, count: level))- \(item.displayText)")
            }
        }
        return lines
    }
}
