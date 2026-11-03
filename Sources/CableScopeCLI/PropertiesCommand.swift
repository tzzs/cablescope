import CableKit
import Foundation

// MARK: - properties 子命令：按 IOKit 类名枚举 IORegistry 条目，输出全量属性
//
// 用法：cablescope properties [ClassName] [--json]
// 默认类名 IOUSBHostDevice；--json 输出结构化结果（便于管道/脚本消费）。

extension CableScopeCLI {
    static let defaultRegistryClassName = "IOUSBHostDevice"

    static func runProperties(className: String, json: Bool) async throws {
        let result = await RegistryService().enumerate(matchingClass: className)
        let entries = result.entries

        if json {
            // stdout 必须保持纯 JSON（管道友好），所以完整性提示走 stderr。
            // 静默截断会让脚本把"前 256 条"当成"全部"，结论建立在残缺数据上。
            if result.truncated {
                writeStandardError(L("警告：条目数超过上限 %lld，结果已截断（仅显示前 %lld 条）。",
                                     RegistryService.maxEntries, entries.count))
            }
            if result.failedCount > 0 {
                writeStandardError(L("警告：另有 %lld 个条目的属性无法读取。", result.failedCount))
            }
            print(try jsonOutput(entries))
            return
        }

        print(textOutput(entries, className: className, truncated: result.truncated, failedCount: result.failedCount))
    }

    /// JSON 输出（纯函数：只依赖 entries，便于单测）。
    static func jsonOutput(_ entries: [RegistryEntrySnapshot]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(entries)
        } catch {
            throw RuntimeError(L("JSON 编码失败：%@", String(describing: error)))
        }
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    /// 文本输出（纯函数：只依赖 entries，便于单测）。
    ///
    /// `truncated` / `failedCount` 由调用方从 `RegistryService.enumerate` 拿到的真实
    /// 完整性标志传入，默认值便于只关心条目内容的调用点。
    static func textOutput(_ entries: [RegistryEntrySnapshot],
                           className: String,
                           truncated: Bool = false,
                           failedCount: Int = 0) -> String {
        // "一条都没有"有两种成因：该类确实没有条目，还是条目都在、但属性一条也读不出来。
        // 后者说成"未找到类"会让用户以为类名写错了，排查方向整个跑偏。
        if entries.isEmpty, !truncated, failedCount == 0 {
            return Term.dim(L("未找到类「%@」的 IORegistry 条目。", className))
        }

        var lines: [String] = [Term.dim(headerLine(className: className,
                                                    count: entries.count,
                                                    truncated: truncated,
                                                    failedCount: failedCount))]
        if failedCount > 0 {
            // 一条都没读出来时不能说"另有"——"另有"预设了前面还有成功的条目。
            lines.append(Term.dim(entries.isEmpty
                ? L("有 %lld 个条目的属性无法读取。", failedCount)
                : L("另有 %lld 个条目的属性无法读取。", failedCount)))
        }
        for entry in entries {
            lines.append("")
            lines.append(Term.bold("\(entry.displayTitle)  [\(entry.className) · registryID \(entry.registryID)]"))
            lines.append(contentsOf: RegistryText.render(entry.properties))
        }
        return lines.joined(separator: "\n")
    }

    /// 标题行：截断、全部读取失败、正常三种情况各是**一句不同的话**，
    /// 各自一个 key（术语表「整句一个 key」）。
    private static func headerLine(className: String, count: Int,
                                   truncated: Bool, failedCount: Int) -> String {
        if truncated {
            return L("类「%@」共 %lld 条条目（已截断，枚举上限 %lld）", className, count, RegistryService.maxEntries)
        }
        if count == 0, failedCount > 0 {
            // 该类的条目存在（否则 failedCount 为 0），只是属性全读不出来。
            // 不能沿用"共 0 条条目"——那会让用户以为这个类在注册表里是空的。
            return L("类「%@」的条目属性均无法读取", className)
        }
        return L("类「%@」共 %lld 条条目（枚举上限 %lld）", className, count, RegistryService.maxEntries)
    }

    /// 写 stderr（stdout 留给 JSON 数据本身）。
    private static func writeStandardError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
