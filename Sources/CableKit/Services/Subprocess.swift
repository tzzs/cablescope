import Foundation

// MARK: - 子进程辅助（system_profiler 等外部命令）
//
// `DisplayService` 与 `ThunderboltService` 是仅有的两个会拉起 `system_profiler` 子进程的
// 服务，二者的调用方式完全一致（绝对路径 + 参数、只取 stdout、非零退出即视为无数据）。
// 抽到这里有两层意义：
//
// 1. **避免重复**：两份一模一样的 `Process` 拼装代码，改一处漏一处的概率不低。
// 2. **堵住一类静默失败**：子进程读取 stdout 时若外部命令输出超过管道缓冲区（64 KiB），
//    写入方会阻塞在 write、读取方在 `readDataToEndOfFile`——两者都在同一进程里，
//    读端在写端之前就绪时不会死锁，但**先 `waitUntilExit()` 再读**的写法会死锁。
//    这里固定「先读完 stdout、再 wait」的顺序，并显式把 stderr 接到丢弃管道上
//    （否则子进程写满 stderr 缓冲区同样会阻塞）。
//
// 失败一律返回 nil：外部命令不可用、退出码非零、输出不是 UTF-8——都降级为「该维度无数据」，
// 与服务层的 graceful degradation 策略一致（单维度缺失不拖垮整机快照）。

/// 拉起外部命令并取其标准输出。
enum Subprocess {
    /// 执行 `launchPath` 并返回其 stdout（UTF-8）。
    ///
    /// - Returns: 命令成功退出（退出码 0）且输出可解码为 UTF-8 时返回输出文本；
    ///   其余情况（无法启动、非零退出、输出非 UTF-8）返回 nil。
    static func run(_ launchPath: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        // stderr 接到**真正的黑洞**（/dev/null），不是 `Pipe()`：
        // `Pipe()` 的读端从不有人读，它只是一个 64 KiB 的缓冲区——子进程写满后
        // write 阻塞，而我们正阻塞在 stdout 的 `readDataToEndOfFile`（等 EOF），
        // 子进程又退不出 → 死锁。`FileHandle.nullDevice` 没有任何缓冲区，写多少都不阻塞。
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil // 命令不存在或无执行权限
        }

        // 顺序要紧：先读完 stdout 再 wait。子进程退出前可能仍在写管道，
        // 反过来（先 wait）会在输出量大时死锁。
        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
