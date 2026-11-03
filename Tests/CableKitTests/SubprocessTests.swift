import Foundation
import XCTest
@testable import CableKit

/// `Subprocess` 测试：外部命令调用封装。
///
/// 这些用例不依赖具体硬件，只依赖系统自带的 `/bin/echo`、`/bin/sh` 等，因此在任何
/// 机器上（含 CI 的空 runner）都能跑。
final class SubprocessTests: XCTestCase {
    func testCapturesStandardOutput() {
        let output = Subprocess.run("/bin/echo", arguments: ["hello"])
        XCTAssertEqual(output?.trimmingCharacters(in: .whitespacesAndNewlines), "hello")
    }

    func testPassesMultipleArguments() {
        let output = Subprocess.run("/bin/echo", arguments: ["a", "b", "c"])
        XCTAssertEqual(output?.trimmingCharacters(in: .whitespacesAndNewlines), "a b c")
    }

    /// 命令不存在 → nil（不是崩溃，也不是空字符串）。
    func testMissingExecutableReturnsNil() {
        XCTAssertNil(Subprocess.run("/nonexistent/CableScopeNoSuchCommand", arguments: []))
    }

    /// 非零退出码 → nil。这一条重要：`system_profiler` 在某些系统上失败时退出码非零，
    /// 此时必须当"该维度无数据"处理，而不是把错误输出当 JSON 解析。
    func testNonZeroExitStatusReturnsNil() {
        XCTAssertNil(Subprocess.run("/bin/sh", arguments: ["-c", "exit 3"]))
    }

    /// stderr 的输出不应污染 stdout，也不应让命令失败。
    func testStandardErrorDoesNotPolluteOutput() {
        let output = Subprocess.run("/bin/sh", arguments: ["-c", "echo out; echo err 1>&2"])
        XCTAssertEqual(output?.trimmingCharacters(in: .whitespacesAndNewlines), "out")
    }

    /// 大量的 stderr 输出不得死锁。
    ///
    /// stderr 若接到 `Pipe()`（读端从不有人读），子进程写满 64 KiB 缓冲区后 write 阻塞，
    /// 而我们正阻塞在 stdout 的 `readDataToEndOfFile`（等 EOF），子进程又退不出 → 死锁。
    /// 正确做法是接到 `FileHandle.nullDevice`（真黑洞，无缓冲区）。
    ///
    /// 本用例在实现回归时表现为**挂死**而非失败——所以用 `XCTAssert` 之外的
    /// 显式超时保护：子进程超时被杀，测试失败并给出可读信息。
    func testLargeStandardErrorDoesNotDeadlock() {
        let script = "i=0; while [ $i -lt 20000 ]; do echo 0123456789012345678901234567890123456789 1>&2; i=$((i+1)); done; echo done"
        let semaphore = DispatchSemaphore(value: 0)
        var output: String?
        DispatchQueue.global().async {
            output = Subprocess.run("/bin/sh", arguments: ["-c", script])
            semaphore.signal()
        }
        // 20 秒足够跑完 800 KB 的 stderr；超时说明死锁。
        XCTAssertEqual(semaphore.wait(timeout: .now() + 20), .success,
                       "大 stderr 输出导致死锁——stderr 必须接到 /dev/null 而不是无人读的 Pipe()")
        XCTAssertEqual(output?.trimmingCharacters(in: .whitespacesAndNewlines), "done")
    }

    /// 大输出不会死锁：先读完 stdout 再 wait 的顺序必须成立。
    /// 若实现改成「先 waitUntilExit 再读」，子进程写满管道缓冲区后会永久阻塞。
    func testLargeOutputDoesNotDeadlock() {
        // 1 MiB 远大于管道缓冲区（64 KiB），足以暴露「先 wait」的死锁。
        let script = "i=0; while [ $i -lt 20000 ]; do echo 0123456789012345678901234567890123456789; i=$((i+1)); done"
        let output = Subprocess.run("/bin/sh", arguments: ["-c", script])
        XCTAssertNotNil(output)
        XCTAssertEqual(output?.isEmpty, false)
        // 每行 40 字符 + 换行 = 41 字节 × 20000 行
        XCTAssertEqual(output?.count, 20000 * 41)
    }
}
