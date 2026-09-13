import CableKit
import Foundation

// MARK: - 入口：swift run CableScopeCLI <子命令> [flags]
//
// 退出码约定：
// - 0  正常（含 --help）
// - 1  运行期错误（快照失败、写盘失败等，输出到 stderr）
// - 2  用法错误（未知子命令/参数，输出到 stderr）

@main
struct CableScopeCLI {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())

        do {
            switch try Args.parse(arguments) {
            case .help:
                print(Help.text)
            case .snapshot(let pretty):
                try await runSnapshot(pretty: pretty)
            case .pretty:
                try await runPretty()
            case .watch(let interval):
                await runWatch(interval: interval)
            case .rating(let reset):
                try await runRating(reset: reset)
            case .properties(let className, let json):
                try await runProperties(className: className, json: json)
            case .throughput(let volume, let seconds):
                try await runThroughput(volume: volume, seconds: seconds)
            }
        } catch let error as UsageError {
            fail("\(error.description)\n\(UsageError.hint)", exitCode: 2)
        } catch let error as RuntimeError {
            fail(error.description, exitCode: 1)
        } catch {
            fail("发生错误：\(error)", exitCode: 1)
        }
    }

    /// 采集一次快照（snapshot / pretty / rating 共用）
    static func acquireSnapshot() async throws -> CableSnapshot {
        let monitor = CableMonitor()
        do {
            return try await monitor.snapshotNow()
        } catch {
            throw RuntimeError("快照采集失败：\(error)")
        }
    }

    private static func fail(_ message: String, exitCode: Int32) -> Never {
        FileHandle.standardError.write(Data("❌ \(message)\n".utf8))
        exit(exitCode)
    }
}

// MARK: - 帮助文案

enum Help {
    static let text = """
    CableScope CLI — 检测连接数据线的全部信息（充电 / 传输 / 视频 / 线缆评级）

    用法:
      swift run CableScopeCLI [子命令] [选项]
      （不带子命令时默认执行 snapshot）

    子命令:
      snapshot        采集一次快照，输出 JSON（含各设备的 IORegistry 全量属性）
      pretty          以人类可读格式输出当前线缆状态
      watch           持续监听状态变化，变化时打印一行摘要（Ctrl-C 退出）
      rating          记录本次快照并打印线缆评级（基于历史协商峰值推断）
      properties      按类名枚举 IORegistry 条目，输出全量 IOKit 属性
      throughput      对挂载卷做读写基准（默认每阶段 5 秒），实测实际吞吐

    选项:
      --pretty        snapshot: JSON 美化输出
      --interval N    watch: 轮询兜底间隔秒数（默认 2，支持小数）
      --reset         rating: 清空历史评级
      --json          properties: JSON 输出
      --volume PATH   throughput: 目标卷（挂载点路径或卷名，模糊匹配；缺省时
                      仅有一个外部卷则自动选择）
      --seconds N     throughput: 每阶段秒数（默认 5，支持小数，须大于 0）
      -h, --help      显示本帮助

    示例:
      swift run CableScopeCLI snapshot --pretty
      swift run CableScopeCLI watch --interval 5
      swift run CableScopeCLI rating
      swift run CableScopeCLI properties                      # 默认 IOUSBHostDevice
      swift run CableScopeCLI properties AppleSmartBattery
      swift run CableScopeCLI properties IODisplayConnect --json
      swift run CableScopeCLI throughput                      # 仅一个外部卷时自动选择
      swift run CableScopeCLI throughput --volume /Volumes/USB盘 --seconds 3

    说明:
      线缆规格基于协商结果推断，仅供参考。
      properties 类名即 ioreg 的类名（如 IOUSBHostDevice / AppleSmartBattery /
      IODisplayConnect / IOThunderboltPort），无匹配条目时输出为空。
    """
}
