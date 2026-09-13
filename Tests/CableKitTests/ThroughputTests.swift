import XCTest
@testable import CableKit

/// ThroughputTester 测试：用临时目录模拟"卷"，不做任何真实 U 盘写入。
final class ThroughputTests: XCTestCase {
    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThroughputTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // 只读用例会把权限改成 555：先恢复再清理，保证临时目录总能删除
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: workDir.path)
        try? FileManager.default.removeItem(at: workDir)
    }

    // MARK: computeMBps 边界

    func testComputeMBpsBoundaries() throws {
        // 1_000_000 字节 / 1 秒 = 1 MB/s（十进制口径）
        XCTAssertEqual(try XCTUnwrap(ThroughputTester.computeMBps(bytes: 1_000_000, elapsed: 1.0)), 1.0, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(ThroughputTester.computeMBps(bytes: 2_000_000, elapsed: 0.5)), 4.0, accuracy: 1e-12)
        // 零字节是合法测量（速率为 0）
        XCTAssertEqual(try XCTUnwrap(ThroughputTester.computeMBps(bytes: 0, elapsed: 1.0)), 0.0, accuracy: 1e-12)
        // 耗时 ≤ 0 或字节 < 0：无有效测量
        XCTAssertNil(ThroughputTester.computeMBps(bytes: 1_000, elapsed: 0))
        XCTAssertNil(ThroughputTester.computeMBps(bytes: 1_000, elapsed: -1))
        XCTAssertNil(ThroughputTester.computeMBps(bytes: -1, elapsed: 1.0))
    }

    // MARK: measure 全流程（临时目录当"卷"，0.3s × 2 阶段 ≈ 0.6s）

    func testMeasureRunsInTemporaryDirectoryAndCleansUp() async throws {
        let result = try await ThroughputTester.measure(at: workDir,
                                                        secondsPerPhase: 0.3,
                                                        chunkBytes: 256 * 1024)

        XCTAssertEqual(result.mountPoint, workDir.path)
        XCTAssertFalse(result.volumeName.isEmpty)

        // 临时测速文件必须被清理（finally 必删）
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: workDir.path)
            .filter { $0.hasPrefix(".cablescope-throughput-") }
        XCTAssertTrue(leftovers.isEmpty, "临时测速文件应被删除，实际残留：\(leftovers)")

        // 结果数值合理：两阶段各至少写/读一个块，速率 > 0
        XCTAssertGreaterThan(result.bytesWritten, 0)
        XCTAssertGreaterThan(result.bytesRead, 0)
        XCTAssertGreaterThan(try XCTUnwrap(result.writeMBps), 0)
        XCTAssertGreaterThan(try XCTUnwrap(result.readMBps), 0)

        // 总耗时 ≈ 0.6s（每阶段至少 0.3s，容差 ±0.5s 吸收块读写与落盘开销）
        XCTAssertEqual(result.elapsedSeconds, 0.6, accuracy: 0.5)
    }

    // MARK: 只读目录：抛错且不残留临时文件

    func testMeasureThrowsAndCleansUpOnReadOnlyDirectory() async throws {
        // POSIX 555：目录只读不可写（测试进程为普通用户时生效）
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: workDir.path)

        do {
            _ = try await ThroughputTester.measure(at: workDir,
                                                   secondsPerPhase: 0.3,
                                                   chunkBytes: 256 * 1024)
            XCTFail("只读目录应当抛 ThroughputError")
        } catch let error as ThroughputError {
            XCTAssertTrue(error.description.contains("只读") || error.description.contains("不可写"),
                          "错误信息应说明只读/不可写，实际：「\(error.description)」")
        }

        // 抛错路径同样不能残留临时文件
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: workDir.path)
            .filter { $0.hasPrefix(".cablescope-throughput-") }
        XCTAssertTrue(leftovers.isEmpty, "失败路径临时文件也应被清理，实际残留：\(leftovers)")
    }
}
