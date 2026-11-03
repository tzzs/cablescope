import XCTest
@testable import CableKit

final class RegistryIndexSnapshotTests: XCTestCase {
    func testDisplayTitleUsesNonemptyNameOrClassName() {
        XCTAssertEqual(item(name: "Port-USB-C@1").displayTitle, "Port-USB-C@1")
        XCTAssertEqual(item(name: "").displayTitle, "AppleHPMInterfaceType10")
        XCTAssertEqual(item(name: nil).displayTitle, "AppleHPMInterfaceType10")
    }

    func testIdentityUsesRegistryID() {
        XCTAssertEqual(item().id, 42)
    }

    func testSourceSummarySortsPlanesAndLocalizesTemplate() {
        let value = RegistryEntryIndexItem(registryID: 42, name: nil,
                                           className: "AppleHPMInterfaceType10",
                                           planePaths: ["IOService": "service/path", "IODeviceTree": "device/path"])

        XCTAssertEqual(value.sourceSummary(locale: Locale(identifier: "en")),
                       "IORegistry plane sources: IODeviceTree, IOService")
    }

    func testIndexAndDetailResultsPreserveIntegrityFields() {
        let indexed = RegistryIndexResult(entries: [item()], indexedPlanes: ["IOService"],
                                          failedPlanes: ["IODeviceTree"], truncated: true, failedCount: 2)
        let detail = RegistryDetailResult(entry: nil, failed: true)

        XCTAssertEqual(indexed.entries.map(\.registryID), [42])
        XCTAssertEqual(indexed.indexedPlanes, ["IOService"])
        XCTAssertEqual(indexed.failedPlanes, ["IODeviceTree"])
        XCTAssertTrue(indexed.truncated)
        XCTAssertEqual(indexed.failedCount, 2)
        XCTAssertNil(detail.entry)
        XCTAssertTrue(detail.failed)
    }

    private func item(name: String? = "Hub") -> RegistryEntryIndexItem {
        RegistryEntryIndexItem(registryID: 42, name: name, className: "AppleHPMInterfaceType10",
                               planePaths: ["IOService": "service/path"])
    }
}
