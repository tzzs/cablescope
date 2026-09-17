import XCTest
@testable import CableKit

/// `RegistryService`（IOKit 通用属性检查器，撑着 App「IOKit 属性」窗口与 CLI `properties`
/// 子命令）此前没有任何专属测试。这里只覆盖不依赖具体硬件的确定性行为；真机枚举的冒烟
/// 覆盖见 `RealEnvironmentSmokeTests.testRegistryServiceSmoke`。
final class RegistryServiceTests: XCTestCase {
    func testEmptyClassNameReturnsEmptyWithoutTouchingIOKit() async throws {
        let entries = try await RegistryService().listEntries(matchingClass: "")
        XCTAssertTrue(entries.isEmpty)
    }

    func testWhitespaceOnlyClassNameReturnsEmpty() async throws {
        let entries = try await RegistryService().listEntries(matchingClass: "   \n\t")
        XCTAssertTrue(entries.isEmpty)
    }

    func testUnknownClassNameDegradesToEmptyRatherThanThrowing() async throws {
        // 不存在的 IOKit 类名：IOServiceGetMatchingServices 返回失败，
        // 应降级为空数组而不是抛错（属性检查器允许用户输入任意类名试探）。
        let entries = try await RegistryService().listEntries(matchingClass: "NoSuchIOKitClass_CableScopeTest")
        XCTAssertTrue(entries.isEmpty)
    }

    func testWellKnownClassesAreNonEmptyWithUniqueClassNames() {
        let classes = RegistryService.wellKnownClasses
        XCTAssertFalse(classes.isEmpty)
        XCTAssertEqual(Set(classes.map(\.className)).count, classes.count,
                       "默认类名清单不应有重复项")
        XCTAssertTrue(classes.allSatisfy { !$0.className.isEmpty && !$0.label.isEmpty })
    }

    func testMaxEntriesIsPositiveAndBounded() {
        // 上限本身是防御性设计（避免误输入过宽类名拖垮 UI）；值发生意外变化时这里能发现。
        XCTAssertGreaterThan(RegistryService.maxEntries, 0)
        XCTAssertLessThanOrEqual(RegistryService.maxEntries, 1000)
    }
}
