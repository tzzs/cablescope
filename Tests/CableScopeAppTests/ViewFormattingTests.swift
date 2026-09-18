@testable import CableScopeApp
import Foundation
import XCTest

/// 视图层里那些「不画界面、只算文案」的纯函数：它们此前散落在 View 文件里没有任何测试，
/// 但恰恰是边界条件容易悄悄改坏的地方（档位边界、缩写大小写、无读数回退）。
final class ViewFormattingTests: XCTestCase {
    // MARK: - 适配器描述美化

    func testAcronymsAreUppercasedAndOtherWordsCapitalized() {
        XCTAssertEqual(OverviewSectionView.prettyAdapterDescription("pd charger"), "PD Charger")
        XCTAssertEqual(OverviewSectionView.prettyAdapterDescription("usb-c gan charger"), "USB-C GAN Charger")
    }

    func testAlreadyCapitalizedWordsSurviveUnchanged() {
        XCTAssertEqual(OverviewSectionView.prettyAdapterDescription("Apple Adapter"), "Apple Adapter")
    }

    func testEmptyAdapterDescriptionStaysEmpty() {
        XCTAssertEqual(OverviewSectionView.prettyAdapterDescription(""), "")
    }

    // MARK: - 电量图标档位边界

    func testBatteryGlyphBoundaries() {
        // 边界值按「>=」归入高档，这组断言锁死每个分界点归属。
        XCTAssertEqual(BatteryGlyph.symbol(for: 100), "battery.100")
        XCTAssertEqual(BatteryGlyph.symbol(for: 90), "battery.100")
        XCTAssertEqual(BatteryGlyph.symbol(for: 89.9), "battery.75")
        XCTAssertEqual(BatteryGlyph.symbol(for: 60), "battery.75")
        XCTAssertEqual(BatteryGlyph.symbol(for: 59.9), "battery.50")
        XCTAssertEqual(BatteryGlyph.symbol(for: 35), "battery.50")
        XCTAssertEqual(BatteryGlyph.symbol(for: 34.9), "battery.25")
        XCTAssertEqual(BatteryGlyph.symbol(for: 10), "battery.25")
        XCTAssertEqual(BatteryGlyph.symbol(for: 9.9), "battery.0")
        XCTAssertEqual(BatteryGlyph.symbol(for: 0), "battery.0")
    }

    // MARK: - 吞吐文案

    func testSpeedTextFormatsNumberWithOneFractionDigit() {
        XCTAssertEqual(ThroughputSectionView.speedText(123.456, locale: Locale(identifier: "en")), "123.5 MB/s")
    }

    func testSpeedTextFallbackIsLocalizedNotRawChinese() {
        // 回退文案是作为 %@ 插进 LocalizedStringKey 的，不会再被 SwiftUI 查表，
        // 必须自己走 AppLocalization——否则英文界面会显示 "Write 无有效数据"。
        XCTAssertEqual(ThroughputSectionView.speedText(nil, locale: Locale(identifier: "en")), "No valid data")
        XCTAssertEqual(ThroughputSectionView.speedText(nil, locale: Locale(identifier: "zh-Hans")), "无有效数据")
    }

    func testMBTextUsesDecimalMegabytes() {
        XCTAssertEqual(ThroughputSectionView.mbText(1_000_000), "1.0 MB")
        XCTAssertEqual(ThroughputSectionView.mbText(0), "0.0 MB")
    }

    // MARK: - 对端 VID 标签

    func testKnownVendorIDShowsNameWithHex() {
        // 0x05AC = Apple，随 usb-vendors.json 一起打进资源包。
        XCTAssertEqual(SessionDetailSectionView.partnerVIDLabel(0x05AC), "Apple, Inc. (0x05AC)")
    }

    func testUnknownVendorIDFallsBackToHexOnly() {
        XCTAssertEqual(SessionDetailSectionView.partnerVIDLabel(0xFFFE), "0xFFFE")
    }

    func testHexLabelIsZeroPaddedToFourDigits() {
        XCTAssertEqual(SessionDetailSectionView.hexLabel(0x1), "0x0001")
        XCTAssertEqual(SessionDetailSectionView.hexLabel(0xABCD), "0xABCD")
    }
}
