import CableKit
import Foundation

// MARK: - properties 子命令：按 IOKit 类名枚举 IORegistry 条目，输出全量属性
//
// 用法：cablescope properties [ClassName] [--json]
// 默认类名 IOUSBHostDevice；--json 输出结构化结果（便于管道/脚本消费）。

extension CableScopeCLI {
    static let defaultRegistryClassName = "IOUSBHostDevice"

    static func runProperties(className: String, json: Bool) async throws {
        let entries: [RegistryEntrySnapshot]
        do {
            entries = try await RegistryService().listEntries(matchingClass: className)
        } catch {
            throw RuntimeError(L("IORegistry 枚举失败：%@", String(describing: error)))
        }

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data: Data
            do {
                data = try encoder.encode(entries)
            } catch {
                throw RuntimeError(L("JSON 编码失败：%@", String(describing: error)))
            }
            print(String(data: data, encoding: .utf8) ?? "[]")
            return
        }

        if entries.isEmpty {
            print(Term.dim(L("未找到类「%@」的 IORegistry 条目。", className)))
            return
        }

        var lines: [String] = [Term.dim(L("类「%@」共 %lld 条条目（枚举上限 %lld）", className, entries.count, RegistryService.maxEntries))]
        for entry in entries {
            lines.append("")
            lines.append(Term.bold("\(entry.displayTitle)  [\(entry.className) · registryID \(entry.registryID)]"))
            lines.append(contentsOf: RegistryText.render(entry.properties))
        }
        print(lines.joined(separator: "\n"))
    }
}
