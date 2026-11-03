import CableKit
import Foundation
import XCTest
@testable import CableScopeCLI

/// `properties` 子命令：文本/JSON 输出的渲染与"类名查不到条目"的降级路径。
final class PropertiesCommandTests: XCTestCase {
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

    private func makeEntry(registryID: UInt64 = 42,
                           name: String? = "Port-USB-C@1",
                           className: String = "AppleHPMInterfaceType10") -> RegistryEntrySnapshot {
        RegistryEntrySnapshot(
            registryID: registryID,
            name: name,
            className: className,
            properties: [
                "ConnectionActive": .boolean(true),
                "PortType": .string("USB-C"),
            ])
    }

    // MARK: 文本输出

    /// 查不到条目时只给一句提示，不打印表头。
    func testTextOutputForUnknownClassIsASingleNotice() {
        let text = CLITestSupport.strippingANSI(
            CableScopeCLI.textOutput([], className: "CableScopeNoSuchClass"))
        XCTAssertEqual(text, "未找到类「CableScopeNoSuchClass」的 IORegistry 条目。")
        XCTAssertFalse(text.contains("共 0 条条目"))
    }

    func testTextOutputListsEntryAndItsProperties() {
        let text = CLITestSupport.strippingANSI(
            CableScopeCLI.textOutput([makeEntry()], className: "AppleHPMInterfaceType10"))

        XCTAssertTrue(text.contains("类「AppleHPMInterfaceType10」共 1 条条目（枚举上限 256）"), text)
        XCTAssertTrue(text.contains("Port-USB-C@1  [AppleHPMInterfaceType10 · registryID 42]"), text)
        // 属性按键名字典序渲染，值按 ioreg 习惯（布尔 Yes/No）；顶层属性不带缩进。
        XCTAssertTrue(text.contains("ConnectionActive: Yes"), text)
        XCTAssertTrue(text.contains("PortType: USB-C"), text)
    }

    /// 条目没有名字时用类名当标题（RegistryEntrySnapshot.displayTitle 的规则）。
    func testTextOutputUsesClassNameWhenEntryHasNoName() {
        let entry = makeEntry(name: nil)
        let text = CLITestSupport.strippingANSI(CableScopeCLI.textOutput([entry], className: "IOUSBHostDevice"))
        XCTAssertTrue(text.contains("AppleHPMInterfaceType10  [AppleHPMInterfaceType10 · registryID 42]"), text)
    }

    // MARK: 截断可见性

    /// 未截断时标题行**不**出现"已截断"字样。
    ///
    /// 这一条是反向断言：截断提示如果无条件显示，等于每次都喊狼来了，用户会
    /// 学会忽略它 —— 那时它对真正被截断的情况也失效了。
    func testTextOutputDoesNotClaimTruncationWhenNotTruncated() {
        let text = CLITestSupport.strippingANSI(
            CableScopeCLI.textOutput([makeEntry()], className: "AppleHPMInterfaceType10", truncated: false))
        XCTAssertTrue(text.contains("共 1 条条目"), text)
        XCTAssertFalse(text.contains("已截断"), "未截断时不得声称已截断：\(text)")
    }

    /// 截断时标题行必须说出来。
    ///
    /// `RegistryService` 触及 256 条上限就停，用户看到的却只有 256 条——不提示的话，
    /// 排查结论就建立在"这是全部"的错误前提上。
    func testTextOutputSaysTruncatedWhenResultIsIncomplete() {
        let entries = (0..<256).map { makeEntry(registryID: UInt64($0)) }
        let text = CLITestSupport.strippingANSI(
            CableScopeCLI.textOutput(entries, className: "IOService", truncated: true))
        XCTAssertTrue(text.contains("共 256 条条目"), text)
        XCTAssertTrue(text.contains("已截断"), "结果不完整时必须声明已截断：\(text)")
    }

    func testAllPropertyReadsFailWithoutClaimingClassIsAbsent() {
        let text = CLITestSupport.strippingANSI(
            CableScopeCLI.textOutput([], className: "IOService", failedCount: 3))
        XCTAssertFalse(text.contains("未找到"), text)
        XCTAssertTrue(text.contains("3 个条目的属性无法读取"), text)
    }

    func testEmptyTruncatedResultStillReportsTruncationAndFailures() {
        let text = CLITestSupport.strippingANSI(
            CableScopeCLI.textOutput([], className: "IOService", truncated: true, failedCount: 256))
        XCTAssertFalse(text.contains("未找到"), text)
        XCTAssertTrue(text.contains("已截断"), text)
        XCTAssertTrue(text.contains("256 个条目的属性无法读取"), text)
    }

    // MARK: JSON 输出

    func testJSONOutputOfEmptyResultIsAnEmptyArray() throws {
        let json = try CableScopeCLI.jsonOutput([])
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        XCTAssertEqual((object as? [Any])?.count, 0, "空结果应编码成空数组：\(json)")
    }

    func testJSONOutputIsValidJSONWithEntryFields() throws {
        let json = try CableScopeCLI.jsonOutput([makeEntry()])
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        let array = try XCTUnwrap(object as? [[String: Any]])
        XCTAssertEqual(array.count, 1)
        XCTAssertEqual(array[0]["registryID"] as? NSNumber, 42)
        XCTAssertEqual(array[0]["className"] as? String, "AppleHPMInterfaceType10")
        XCTAssertEqual(array[0]["name"] as? String, "Port-USB-C@1")
        // 属性平铺成 JSON 标量（不是 tagged enum）
        let properties = try XCTUnwrap(array[0]["properties"] as? [String: Any])
        XCTAssertEqual(properties["ConnectionActive"] as? Bool, true)
        XCTAssertEqual(properties["PortType"] as? String, "USB-C")
    }

    // MARK: 命令体（真实调用，走 IOKit 枚举）

    /// 真实命令体：不存在的类名 → 枚举为空 → 打印"未找到"提示，不崩溃、不输出表头。
    func testRunPropertiesWithUnknownClassPrintsNotice() async throws {
        let output = try await CLITestSupport.captureStandardOutput {
            try await CableScopeCLI.runProperties(className: "CableScopeNoSuchClass", json: false)
        }
        XCTAssertTrue(output.contains("未找到类「CableScopeNoSuchClass」的 IORegistry 条目。"), output)
    }

    /// 真实命令体 + `--json`：输出必须是可解析的 JSON 数组（空数组即可，机器上有没有该类名不影响）。
    func testRunPropertiesWithJSONFlagEmitsParsableJSON() async throws {
        let output = try await CLITestSupport.captureStandardOutput {
            try await CableScopeCLI.runProperties(className: "CableScopeNoSuchClass", json: true)
        }
        let object = try JSONSerialization.jsonObject(with: Data(output.utf8))
        XCTAssertTrue(object is [Any], "JSON 输出应是数组：\(output)")
    }
}
