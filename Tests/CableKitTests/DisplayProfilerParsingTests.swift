import XCTest
@testable import CableKit

/// DisplayService 的 system_profiler JSON 解析测试。
final class DisplayProfilerParsingTests: XCTestCase {
    func testParseGPUWithDisplay() {
        let root: [String: Any] = [
            "SPDisplaysDataType": [
                [
                    "sppci_model": "Apple M3",
                    "spdisplays_ndrvs": [
                        [
                            "_name": "Color LCD",
                            "_spdisplays_displayID": "1",
                            "spdisplays_pixelresolution": "2940 x 1912",
                        ],
                    ],
                ],
            ],
        ]
        let info = DisplayProfilerParsing.parse(root: root)
        XCTAssertEqual(info[1]?.name, "Color LCD")
        XCTAssertNil(info[1]?.linkRate, "内置显示器无 link 字段时不得编造")
    }

    func testLinkRateExtractedAndPrefixStripped() {
        let ndrv: [String: Any] = [
            "spdisplays_link_rate": "spdisplays_hbr3",
            "_spdisplays_displayID": "1",
        ]
        XCTAssertEqual(DisplayProfilerParsing.linkRateLabel(from: ndrv), "hbr3", "去掉 spdisplays_ 前缀但保留原值")
    }

    func testLinkRateIgnoresDisplayIDKeyAndNonStrings() {
        // 键名同时含 link 和 displayid → 跳过（避免把 displayID 误当链路速率）
        let tricky: [String: Any] = ["spdisplays_displayid_link": "value", "_spdisplays_displayID": "1"]
        XCTAssertNil(DisplayProfilerParsing.linkRateLabel(from: tricky))
        // 非字符串值忽略
        let numeric: [String: Any] = ["spdisplays_link_rate": 42]
        XCTAssertNil(DisplayProfilerParsing.linkRateLabel(from: numeric))
        // 空字典
        XCTAssertNil(DisplayProfilerParsing.linkRateLabel(from: [:]))
    }

    /// 多个键都含 "link" 时必须给出**稳定**的结果。
    ///
    /// `[String: Any]` 的迭代顺序取决于哈希种子。Swift 的哈希种子**按进程固定**，
    /// 所以同一进程内多次调用顺序一致（这一点无法在本进程内测出来）；真正会变的是
    /// **跨进程**——同一台机器上两次启动，同一份 `system_profiler` 输出可能给出不同的
    /// 迭代顺序，于是同一次插拔在两次运行里报出不同的链路速率。改为按键名字典序遍历后，
    /// 结果与哈希种子无关，跨进程也可复现。
    func testLinkRateIsDeterministicWhenMultipleKeysMatch() {
        let ndrv: [String: Any] = [
            "spdisplays_link_rate": "spdisplays_hbr3",
            "spdisplays_link_rate_min": "spdisplays_hbr2",
            "zzz_link_extra": "spdisplays_hbr1",
            "_spdisplays_displayID": "1",
        ]
        // 字典序最小且符合条件的键是 "spdisplays_link_rate"（先于 "spdisplays_link_rate_min"）。
        // 这条精确断言才是判别力所在：原生哈希序下命中哪个键是不确定的。
        XCTAssertEqual(DisplayProfilerParsing.linkRateLabel(from: ndrv), "hbr3")
    }

    func testDisplayIDRegisteredAsHexAndDecimal() {
        var dict: [CGDirectDisplayID: ProfilerDisplayInfo] = [:]
        // "3f" 是合法 hex；同时 "3f" 不是合法 decimal，只注册 hex
        DisplayProfilerParsing.register(idString: "3f", info: ProfilerDisplayInfo(name: "A", linkRate: nil), into: &dict)
        XCTAssertNotNil(dict[0x3f])
        // "1" 既是 hex 又是 decimal，注册到同一个 id
        DisplayProfilerParsing.register(idString: "1", info: ProfilerDisplayInfo(name: "B", linkRate: nil), into: &dict)
        XCTAssertEqual(dict[1]?.name, "B")
    }

    func testMissingNDrvsReturnsEmpty() {
        let root: [String: Any] = ["SPDisplaysDataType": [["sppci_model": "GPU"]]]
        XCTAssertTrue(DisplayProfilerParsing.parse(root: root).isEmpty)
        XCTAssertTrue(DisplayProfilerParsing.parse(root: [:]).isEmpty)
    }
}
