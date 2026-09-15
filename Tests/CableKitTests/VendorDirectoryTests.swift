import XCTest
@testable import CableKit

/// VendorDirectory 的注入式测试（不依赖 bundle 资源）+ shared 加载真实资源的冒烟。
final class VendorDirectoryTests: XCTestCase {
    /// 注入表：正常查名。
    func testNameLookup() {
        let directory = VendorDirectory(entries: [
            0x05AC: "Apple, Inc.",
            0x0BDA: "Realtek Semiconductor Corp.",
        ])
        XCTAssertEqual(directory.name(forVendorID: 0x05AC), "Apple, Inc.")
        XCTAssertEqual(directory.name(forVendorID: 0x0BDA), "Realtek Semiconductor Corp.")
        XCTAssertEqual(directory.knownCount, 2)
    }

    /// 注入表：未收录的 VID 返回 nil。
    func testUnknownVendorIDReturnsNil() {
        let directory = VendorDirectory(entries: [0x05AC: "Apple, Inc."])
        XCTAssertNil(directory.name(forVendorID: 0x1234), "未收录 VID 应返回 nil，由调用方回退 hex 展示")
        XCTAssertEqual(directory.knownCount, 1)
    }

    /// 空表：查名恒 nil，计数为 0（对应 Bundle 资源缺失时的回退形态）。
    func testEmptyTable() {
        let directory = VendorDirectory(entries: [:])
        XCTAssertEqual(directory.knownCount, 0)
        XCTAssertNil(directory.name(forVendorID: 0x05AC))
    }

    /// JSON 数据解析：hex 字符串 → UInt32、非法条目跳过、结构错误回退空表。
    func testParseHexVidsFromData() {
        let json = """
        {"source":"test","vendors":[
            {"vid":"05AC","name":"Apple, Inc."},
            {"vid":"0bda","name":"Realtek Semiconductor Corp."},
            {"vid":"zzzz","name":"bogus entry skipped"},
            {"vid":"","name":"empty vid skipped"}
        ]}
        """
        let entries = VendorDirectory.parse(Data(json.utf8))
        XCTAssertEqual(entries[0x05AC], "Apple, Inc.")
        XCTAssertEqual(entries[0x0BDA], "Realtek Semiconductor Corp.", "小写 hex 也应可解析")
        XCTAssertEqual(entries.count, 2, "非法 vid 条目应被跳过")

        XCTAssertEqual(VendorDirectory.parse(Data("not json".utf8)).count, 0,
                       "结构错误应回退空表而非抛错")
    }

    /// loadBundledJSON：候选路径里 bundle 整体不存在时安全返回 nil（不崩溃）。
    ///
    /// 回归用例——此前 `shared` 直接调用 SwiftPM 生成的 `Bundle.module`，
    /// 该访问器在 bundle 整体缺失时会内部 fatalError，绕过任何 guard/try? 防护，
    /// 在真实打包不完整的 .app 上造成过崩溃（VendorDirectory.swift 崩溃现场：
    /// closure #1 in variable initialization expression of static NSBundle.module）。
    func testLoadBundledJSONReturnsNilWhenBundleMissing() {
        let data = VendorDirectory.loadBundledJSON(
            bundleFileName: "NoSuchBundle.bundle",
            candidates: [URL(fileURLWithPath: NSTemporaryDirectory())]
        )
        XCTAssertNil(data, "候选路径都找不到 bundle 时应返回 nil，而不是崩溃")
    }

    /// shared：加载随包真实资源 usb-vendors.json。
    /// 该断言依赖 Bundle.module 资源在测试环境可用；不可用时（shared 回退空表）跳过并说明。
    func testSharedLoadsBundledJSON() throws {
        guard VendorDirectory.shared.knownCount > 0 else {
            throw XCTSkip("Bundle.module 资源在测试环境不可用（shared 已按约定回退空表）")
        }
        XCTAssertGreaterThanOrEqual(VendorDirectory.shared.knownCount, 120,
                                    "内置库应收录不少于 120 家常见厂商")
        XCTAssertEqual(VendorDirectory.shared.name(forVendorID: 0x05AC), "Apple, Inc.")
        XCTAssertEqual(VendorDirectory.shared.name(forVendorID: 0x0BDA), "Realtek Semiconductor Corp.")
        XCTAssertEqual(VendorDirectory.shared.name(forVendorID: 0x8086), "Intel Corp.")
        XCTAssertNil(VendorDirectory.shared.name(forVendorID: 0xFFFF), "未收录 VID 不应杜撰厂商名")
    }
}
