import XCTest
@testable import CableKit

/// `RegistryService`（IOKit 通用属性检查器，撑着 App「IOKit 属性」窗口与 CLI `properties`
/// 子命令）此前没有任何专属测试。这里只覆盖不依赖具体硬件的确定性行为；真机枚举的冒烟
/// 覆盖见 `RealEnvironmentSmokeTests.testRegistryServiceSmoke`。
final class RegistryServiceTests: XCTestCase {
    func testEmptyClassNameReturnsEmptyWithoutTouchingIOKit() async throws {
        let entries = await RegistryService().listEntries(matchingClass: "")
        XCTAssertTrue(entries.isEmpty)
    }

    func testWhitespaceOnlyClassNameReturnsEmpty() async throws {
        let entries = await RegistryService().listEntries(matchingClass: "   \n\t")
        XCTAssertTrue(entries.isEmpty)
    }

    func testUnknownClassNameDegradesToEmptyRatherThanThrowing() async throws {
        // 不存在的 IOKit 类名：IOServiceGetMatchingServices 返回失败，
        // 应降级为空数组而不是抛错（属性检查器允许用户输入任意类名试探）。
        let entries = await RegistryService().listEntries(matchingClass: "NoSuchIOKitClass_CableScopeTest")
        XCTAssertTrue(entries.isEmpty)
    }

    func testWellKnownClassesAreNonEmptyWithUniqueClassNames() {
        let classes = RegistryService.wellKnownClasses
        XCTAssertFalse(classes.isEmpty)
        XCTAssertEqual(Set(classes.map(\.className)).count, classes.count,
                       "默认类名清单不应有重复项")
        XCTAssertTrue(classes.allSatisfy { !$0.className.isEmpty && !$0.labelKey.isEmpty })
        // 每条都必须有英文译文：labelKey 就是 .strings 的 key，查表落空会原样退回中文，
        // 英文界面的类名下拉框因此会混进中文项——这里直接断言"英文 != 中文 key"。
        for wellKnown in classes {
            XCTAssertNotEqual(wellKnown.label(locale: Locale(identifier: "en")), wellKnown.labelKey,
                              "\(wellKnown.className) 的英文译文缺失")
        }
    }

    func testMaxEntriesIsPositiveAndBounded() {
        // 上限本身是防御性设计（避免误输入过宽类名拖垮 UI）；值发生意外变化时这里能发现。
        XCTAssertGreaterThan(RegistryService.maxEntries, 0)
        XCTAssertLessThanOrEqual(RegistryService.maxEntries, 1000)
    }

    // MARK: - 截断可见性

    /// 空类名走 `enumerate` 也必须是"空且未截断"，不能误报截断。
    func testEnumerateReportsEmptyAndNotTruncated() async throws {
        let result = await RegistryService().enumerate(matchingClass: "")
        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertFalse(result.truncated)
    }

    /// 不存在的类名同理：空结果不是截断。
    func testEnumerateUnknownClassIsNotTruncated() async throws {
        let result = await RegistryService().enumerate(matchingClass: "NoSuchIOKitClass_CableScopeTest")
        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertFalse(result.truncated)
    }

    /// `listEntries` 仍返回裸数组（协议契约未变），且与 `enumerate` 的条目一致。
    func testListEntriesRemainsArrayShaped() async throws {
        let service = RegistryService()
        let entries = await service.listEntries(matchingClass: "AppleSmartBattery")
        let result = await service.enumerate(matchingClass: "AppleSmartBattery")
        XCTAssertEqual(entries.count, result.entries.count)
    }

    /// 截断判定规则本身（纯函数）。
    ///
    /// 真实枚举要触顶 256 条才可能复现，CI 的空 runner 上永远走不到这条路径，
    /// 所以把判定规则抽成纯函数在这里钉住。
    func testTruncationStatusRules() {
        // 没触顶 → 无论后面还有没有，都不算截断。
        XCTAssertFalse(RegistryService.truncationStatus(collectedCount: 10, maxEntries: 256,
                                                        hasMoreRawEntries: true))
        // 刚好触顶且迭代器耗尽 → 该类真的只有这么多条目。
        XCTAssertFalse(RegistryService.truncationStatus(collectedCount: 256, maxEntries: 256,
                                                        hasMoreRawEntries: false))
        // 触顶且迭代器还有货 → 确实被砍掉了后续条目。
        XCTAssertTrue(RegistryService.truncationStatus(collectedCount: 256, maxEntries: 256,
                                                       hasMoreRawEntries: true))
    }

    /// 关键不变式：**没触顶就绝不报截断**。
    ///
    /// 判定用的是"读取成功的条目数"，而属性读取失败的条目同样占用枚举额度——
    /// 若实现误把"成功数 < 上限"当成"肯定没截断"，用户就会在结果被砍掉时
    /// 被告知"这是全部"，排查结论建立在残缺数据上。
    func testTruncationNeverReportedBeforeLimit() {
        for count in 0..<RegistryService.maxEntries {
            XCTAssertFalse(RegistryService.truncationStatus(collectedCount: count,
                                                            maxEntries: RegistryService.maxEntries,
                                                            hasMoreRawEntries: true),
                           "未触顶（\(count) < \(RegistryService.maxEntries)）时不得报截断")
        }
    }

    /// 不存在的类名：空结果、没截断、也没有读取失败的条目。
    func testEnumerationReportsNoFailuresForUnknownClass() async throws {
        let result = await RegistryService().enumerate(matchingClass: "NoSuchIOKitClass_CableScopeTest")
        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertFalse(result.truncated)
        XCTAssertEqual(result.failedCount, 0)
        XCTAssertTrue(result.isComplete)
    }

    /// `isComplete` 汇总两种不完整：截断与属性读取失败。
    func testIsCompleteReflectsBothIncompletenessKinds() {
        XCTAssertTrue(RegistryEnumerationResult(entries: [], truncated: false, failedCount: 0).isComplete)
        XCTAssertFalse(RegistryEnumerationResult(entries: [], truncated: true, failedCount: 0).isComplete)
        XCTAssertFalse(RegistryEnumerationResult(entries: [], truncated: false, failedCount: 3).isComplete)
    }
}
