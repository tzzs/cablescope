import Darwin
import Foundation
@testable import CableScopeCLI

/// CLI 测试的公共辅助。
enum CLITestSupport {
    /// 捕获 `body` 执行期间写到 stdout 的内容。
    ///
    /// CLI 用 `print` 输出，走的是 C 的 `stdout`——重定向 `FileHandle.standardOutput`
    /// 对它无效（Swift 的 print 写的是 C 层的 FILE*），所以这里用 `dup2` 把 fd 1
    /// 指向管道，执行完再还原。
    ///
    /// 注意：管道缓冲区有限，输出过大时写端会阻塞——只用于断言小段输出的命令。
    static func captureStandardOutput(_ body: () async throws -> Void) async rethrows -> String {
        let pipe = Pipe()
        fflush(stdout)
        let saved = dup(STDOUT_FILENO)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        do {
            try await body()
        } catch {
            fflush(stdout)
            dup2(saved, STDOUT_FILENO)
            close(saved)
            pipe.fileHandleForWriting.closeFile()
            _ = pipe.fileHandleForReading.readDataToEndOfFile()
            throw error
        }
        fflush(stdout)
        dup2(saved, STDOUT_FILENO)
        close(saved)
        pipe.fileHandleForWriting.closeFile()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return strippingANSI(String(decoding: data, as: UTF8.self))
    }

    /// 去掉 ANSI 转义序列。
    ///
    /// `Term.bold`/`Term.dim` 只在 stdout 是 TTY 时才加转义序列，而 `swift test` 的
    /// stdout 可能就是终端——断言前统一剥掉，结果才与运行环境无关。
    static func strippingANSI(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
    }

    /// 逐行剥离 ANSI 转义。
    static func strippingANSILines(_ lines: [String]) -> [String] {
        lines.map { strippingANSI($0) }
    }
}
