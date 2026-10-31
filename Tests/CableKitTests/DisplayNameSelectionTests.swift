import CoreGraphics
import XCTest
@testable import CableKit

/// 显示器名称的候选选择逻辑测试。
///
/// 钉住的是**选择逻辑**，不是具体字符串：系统给出的名字（`NSScreen.localizedName`、
/// EDID 产品名）不是我们的文案——它们跟随系统的 Language & Region，不随 App 内语言
/// 切换（见 AGENTS.md「Localization」），因此不存在"该显示成什么文案"的正确答案。
final class DisplayNameSelectionTests: XCTestCase {
    private func candidate(_ displayID: CGDirectDisplayID, _ name: String) -> DisplayNameSelection.ScreenCandidate {
        DisplayNameSelection.ScreenCandidate(displayID: displayID, name: name)
    }

    /// 有 NSScreen 候选时优先用系统名（它是用户在自己系统里看到的名字）。
    func testScreenNameWinsOverProfilerName() {
        let name = DisplayNameSelection.select(
            screens: [candidate(1, "内建视网膜显示器")],
            displayID: 1,
            profilerName: "Color LCD")
        XCTAssertEqual(name, "内建视网膜显示器")
    }

    /// 没有 NSScreen 对应（显示器刚插上、或不是 NSScreen 可表示的屏）→ 用 system_profiler 的名字。
    func testFallsBackToProfilerNameWhenNoScreenMatches() {
        let name = DisplayNameSelection.select(
            screens: [candidate(2, "DELL U2723QE")],
            displayID: 1,
            profilerName: "Color LCD")
        XCTAssertEqual(name, "Color LCD")
    }

    /// 屏幕候选为空时同样回退到 system_profiler。
    func testFallsBackToProfilerNameWhenThereAreNoScreens() {
        XCTAssertEqual(DisplayNameSelection.select(screens: [], displayID: 1, profilerName: "Color LCD"),
                       "Color LCD")
    }

    /// 系统名是空串时不算有效名字 → 回退 system_profiler。
    func testEmptyScreenNameFallsBackToProfilerName() {
        let name = DisplayNameSelection.select(
            screens: [candidate(1, "")],
            displayID: 1,
            profilerName: "Color LCD")
        XCTAssertEqual(name, "Color LCD")
    }

    /// 两个来源都没有名字 → nil（调用方据此显示"未命名"）。
    func testNilWhenNeitherSourceHasAName() {
        XCTAssertNil(DisplayNameSelection.select(screens: [candidate(1, "")], displayID: 1, profilerName: nil))
        XCTAssertNil(DisplayNameSelection.select(screens: [], displayID: 1, profilerName: nil))
    }

    /// 匹配按 displayID 走，与候选数组的顺序无关：不能把别的屏的名字安到这台头上。
    func testMatchingIsByDisplayIDNotByOrder() {
        let screens = [candidate(7, "第一台"), candidate(9, "第二台")]

        XCTAssertEqual(DisplayNameSelection.select(screens: screens, displayID: 9, profilerName: nil), "第二台")
        XCTAssertEqual(DisplayNameSelection.select(screens: screens.reversed(), displayID: 9, profilerName: nil),
                       "第二台")
    }

    /// 名字按系统原样透传：不做裁剪、不做翻译（外部显示器的 EDID 产品名是厂商专有名词）。
    func testScreenNameIsPassedThroughVerbatim() {
        let raw = "DELL U2723QE"
        XCTAssertEqual(DisplayNameSelection.select(screens: [candidate(1, raw)], displayID: 1, profilerName: nil),
                       raw)
    }
}
