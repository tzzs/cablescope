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
