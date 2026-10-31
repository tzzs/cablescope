import CableKit
import Foundation
import XCTest
@testable import CableScopeCLI

/// `throughput` 子命令：卷匹配、时长/结果文案与"找不到卷"的错误路径。
final class ThroughputCommandTests: XCTestCase {
    private var savedLocale = CLILanguage.locale

    override func setUp() {
        super.setUp()
        savedLocale = CLILanguage.locale
        CLILanguage.locale = Locale(identifier: "zh-Hans")
    }

    override func tearDown() {
        CLILanguage.locale = savedLocale
        super.tearDown()
    }

    private let candidates: [(url: URL, name: String, isRemovable: Bool)] = [
        (URL(fileURLWithPath: "/Volumes/USB"), "USB", true),
        (URL(fileURLWithPath: "/Volumes/Backup"), "Backup", false),
    ]

    // MARK: 卷匹配

    func testMatchVolumeByExactName() {
        let match = CableScopeCLI.matchVolume("USB", in: candidates)
        XCTAssertEqual(match?.name, "USB")
        XCTAssertEqual(match?.url.path, "/Volumes/USB")
    }

    /// 名字大小写不敏感。
    func testMatchVolumeIsCaseInsensitive() {
        XCTAssertEqual(CableScopeCLI.matchVolume("usb", in: candidates)?.name, "USB")
        XCTAssertEqual(CableScopeCLI.matchVolume("backup", in: candidates)?.name, "Backup")
    }

    /// 也接受挂载点路径（同样大小写不敏感）。
    func testMatchVolumeByExactMountPoint() {
        XCTAssertEqual(CableScopeCLI.matchVolume("/Volumes/Backup", in: candidates)?.name, "Backup")
        XCTAssertEqual(CableScopeCLI.matchVolume("/volumes/backup", in: candidates)?.name, "Backup")
    }

    /// 精确匹配优先于模糊匹配：候选里同时有 "USB" 和 "USB-ARCHIVE" 时选前者。
    func testExactMatchWinsOverFuzzyMatch() {
        let mixed: [(url: URL, name: String, isRemovable: Bool)] = [
            (URL(fileURLWithPath: "/Volumes/USB-ARCHIVE"), "USB-ARCHIVE", true),
            (URL(fileURLWithPath: "/Volumes/USB"), "USB", true),
        ]
        XCTAssertEqual(CableScopeCLI.matchVolume("USB", in: mixed)?.name, "USB")
    }

    /// 找不到精确匹配时退到包含匹配（卷名或挂载点任一命中即可）。
    func testFuzzyMatchBySubstring() {
        XCTAssertEqual(CableScopeCLI.matchVolume("BACK", in: candidates)?.name, "Backup")
        XCTAssertEqual(CableScopeCLI.matchVolume("/Volumes/USB", in: candidates)?.name, "USB")
    }

    func testNoMatchReturnsNil() {
        XCTAssertNil(CableScopeCLI.matchVolume("cablescope-no-such-volume-4f3a", in: candidates))
        XCTAssertNil(CableScopeCLI.matchVolume("usb", in: []))
    }

    // MARK: 文案

    /// 整数秒不带小数点，小数秒保留一位。
    func testSecondsLabel() {
        XCTAssertEqual(CableScopeCLI.secondsLabel(5), "5")
        XCTAssertEqual(CableScopeCLI.secondsLabel(2.5), "2.5")
        XCTAssertEqual(CableScopeCLI.secondsLabel(0.5), "0.5")
    }

    func testResultLinesShowBothRates() {
        let result = ThroughputResult(volumeName: "USB", mountPoint: "/Volumes/USB",
                                       writeMBps: 12.34, readMBps: 56.78,
                                       bytesWritten: 1_000_000, bytesRead: 2_000_000,
                                       elapsedSeconds: 3.25)
        let lines = CLITestSupport.strippingANSILines(CableScopeCLI.resultLines(result))

        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].contains("写入 12.3 MB/s · 读取 56.8 MB/s"), lines[0])
        XCTAssertTrue(lines[1].contains("已写入 1.0 MB · 已读取 2.0 MB · 总耗时 3.2 秒"), lines[1])
        XCTAssertTrue(lines[2].contains("实测吞吐 ≠ 协商速率"), lines[2])
    }

    /// 速率算不出来时显示"无有效数据"，而不是 0.0 MB/s。
    func testResultLinesFallBackToNoData() {
        let result = ThroughputResult(volumeName: "USB", mountPoint: "/Volumes/USB",
                                       writeMBps: nil, readMBps: nil,
                                       bytesWritten: 0, bytesRead: 0, elapsedSeconds: 0)
        let lines = CLITestSupport.strippingANSILines(CableScopeCLI.resultLines(result))

        XCTAssertTrue(lines[0].contains("写入 无有效数据 · 读取 无有效数据"), lines[0])
    }

    func testCandidateLinesForEmptyList() {
        let lines = CLITestSupport.strippingANSILines(CableScopeCLI.candidateLines([]))
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("当前没有可测速的候选卷"), lines[0])
    }

    func testCandidateLinesMarkRemovableAndExternalVolumes() {
        let lines = CLITestSupport.strippingANSILines(CableScopeCLI.candidateLines(candidates))
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].contains("候选卷："), lines[0])
        XCTAssertTrue(lines[1].contains("USB  /Volumes/USB  [可移动]"), lines[1])
        XCTAssertTrue(lines[2].contains("Backup  /Volumes/Backup  [外部]"), lines[2])
    }

    // MARK: 命令体（真实调用）

    /// 真实命令体：指定一个不存在的卷 → 报错退出（退出码 1 的来源），而不是去测速。
    func testRunThroughputWithUnknownVolumeFails() async {
        do {
            _ = try await CLITestSupport.captureStandardOutput {
                try await CableScopeCLI.runThroughput(volume: "cablescope-no-such-volume-4f3a", seconds: 1)
            }
            XCTFail("找不到卷时应当抛出 RuntimeError")
        } catch let error as RuntimeError {
            XCTAssertTrue(
                error.description.contains("未找到与「cablescope-no-such-volume-4f3a」匹配的卷"),
                error.description)
        } catch {
            XCTFail("错误类型不对：\(error)")
        }
    }
}
