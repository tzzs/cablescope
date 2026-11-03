import XCTest
@testable import CableKit

/// IORegistry 条目/索引模型的展示规则（纯值类型，无 IO）。
final class RegistryEntryModelTests: XCTestCase {

    // MARK: - 条目展示名

    /// 展示标题优先用条目名；名为空或缺失时退回类名——不能给用户一个空标题。
    func testEntryDisplayTitleFallsBackToClassName() {
        XCTAssertEqual(makeEntry(name: "Port-USB-C@1").displayTitle, "Port-USB-C@1")
        XCTAssertEqual(makeEntry(name: "").displayTitle, "AppleHPMInterfaceType10")
        XCTAssertEqual(makeEntry(name: nil).displayTitle, "AppleHPMInterfaceType10")
    }

    func testEntryIdentityUsesRegistryID() {
        XCTAssertEqual(makeEntry().id, 7)
    }

    // MARK: - 次要展示属性（同一类名下的多个条目靠它区分）

    /// 端口号是雷雳端口唯一可靠的区分字段（Description 恒为 "Port is inactive"）。
    func testDisambiguatingSubtitleUsesFirstNonemptyCandidate() {
        let entry = makeEntry(className: "IOThunderboltPort",
                              properties: ["Port Number": .number(2)])
        XCTAssertEqual(entry.disambiguatingSubtitle, "Port Number 2")
    }

    /// 候选值全为空时不给副标题——空副标题不如没有。
    func testDisambiguatingSubtitleIsNilWhenCandidatesAreEmpty() {
        let entry = makeEntry(className: "IOThunderboltPort",
                              properties: ["Port Number": .string("")])
        XCTAssertNil(entry.disambiguatingSubtitle)
    }

    /// 没有为该类定义区分字段时不编造副标题。
    func testDisambiguatingSubtitleIsNilForUnknownClass() {
        let entry = makeEntry(className: "AppleSmartBattery",
                              properties: ["Description": .string("whatever")])
        XCTAssertNil(entry.disambiguatingSubtitle)
    }

    /// AppleHPM 端口用 Description 区分（自带 "Port-USB-C@N"）。
    func testDisambiguatingSubtitleForHPMPortUsesDescription() {
        let entry = makeEntry(className: "AppleHPMInterfaceType10",
                              properties: ["Description": .string("Port-USB-C@1")])
        XCTAssertEqual(entry.disambiguatingSubtitle, "Description Port-USB-C@1")
    }

    // MARK: - DisplayPort 链路身份

    /// 链路 id 由端口 + EDID 身份拼成，缺项时用占位符（不同链路不得撞 id）。
    func testDisplayLinkIdentityUsesPortAndEDID() {
        let link = DisplayPortLinkSnapshot(portID: "Port-USB-C@1", isActive: true, isTunneled: false,
                                           linkRateDescription: nil, manufacturerName: nil,
                                           productName: nil, productID: 9987, serialNumber: 10)
        XCTAssertEqual(link.id, "Port-USB-C@1-9987-10")

        let unknown = DisplayPortLinkSnapshot(portID: nil, isActive: false, isTunneled: false,
                                             linkRateDescription: nil, manufacturerName: nil,
                                             productName: nil, productID: nil, serialNumber: nil)
        XCTAssertEqual(unknown.id, "?-0-0")
    }

    // MARK: - 夹具

    private func makeEntry(name: String? = "Hub",
                           className: String = "AppleHPMInterfaceType10",
                           properties: [String: IORegistryValue] = [:]) -> RegistryEntrySnapshot {
        RegistryEntrySnapshot(registryID: 7, name: name, className: className, properties: properties)
    }
}
