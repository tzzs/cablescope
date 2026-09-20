@testable import CableKit
import XCTest

/// CableKit 展示文案的本地化回归。
///
/// 这些文案过去是"顺手拼出来的 Swift 字符串"，从未接入 `KitLocalization`——它们由
/// CableKit 产出、被 App 直接渲染，于是 App 切语言只换得掉自己那层，换不掉这一层，
/// 英文界面里混着 "USB-C 端口 @2" / "雷雳 4 / USB4" / "默认 USB 电流"。
/// 漏翻不会报错（查表落空一律退回中文 key），所以这里逐条断言英文输出。
///
/// 端口展示名（`CableSession.portLabel/shortPortLabel`）的同类断言在 `PortGroupingTests`。
final class KitDisplayTextTests: XCTestCase {
    private let english = Locale(identifier: "en")
    private let chinese = Locale(identifier: "zh-Hans")

    func testCableSpeedClassLabelsHaveEnglish() {
        XCTAssertEqual(CableSpeedClass.usb4Gen3.label(locale: english), "USB4 / Thunderbolt 3 (40 Gbps)")
        XCTAssertEqual(CableSpeedClass.usb32Gen2.label(locale: english), "USB 3.2 Gen2 (10 Gbps)")
        XCTAssertEqual(CableSpeedClass.usb4Gen3.label(locale: chinese), "USB4 / 雷雳 3（40 Gbps）")
        // USB 2.0 没有语言差异，两边必须一致（也验证"无需翻译"不会被误加进表里）。
        XCTAssertEqual(CableSpeedClass.usb2.label(locale: english), "USB 2.0")
    }

    func testCableCurrentRatingLabelsHaveEnglish() {
        XCTAssertEqual(CableCurrentRating.usbDefault.label(locale: english), "Default USB current")
        XCTAssertEqual(CableCurrentRating.reserved.label(locale: english), "Reserved value")
        XCTAssertEqual(CableCurrentRating.fiveAmp.label(locale: english), "5A (≤100W)")
        XCTAssertEqual(CableCurrentRating.fiveAmp.label(locale: chinese), "5A（≤100W）")
    }

    /// `generation` 存的是中文原句（快照要序列化，不能把某种语言写死进数据），
    /// 展示时才查表——这里守住"存的是 key、取的是译文"这条约定。
    func testThunderboltGenerationLabelTranslatesStoredKey() {
        let device = ThunderboltDeviceSnapshot(name: "Dock", vendorName: nil, linkSpeedLabel: nil,
                                               deviceType: nil, generation: "雷雳 4 / USB4")
        XCTAssertEqual(device.generation, "雷雳 4 / USB4", "快照里存的必须仍是中文原句")
        XCTAssertEqual(device.generationLabel(locale: english), "Thunderbolt 4 / USB4")
        XCTAssertEqual(device.generationLabel(locale: chinese), "雷雳 4 / USB4")
    }

    func testThunderboltGenerationLabelIsNilWhenUnknown() {
        let device = ThunderboltDeviceSnapshot(name: "Dock", vendorName: nil, linkSpeedLabel: nil,
                                               deviceType: nil)
        XCTAssertNil(device.generationLabel(locale: english))
    }

    /// 内建屏的 `name` 来自 `NSScreen.localizedName`，跟随的是系统语言而不是 App 的
    /// 语言开关——系统中文时它就是"内建视网膜显示器"。展示名必须绕开它。
    func testBuiltinDisplayUsesOwnLabelInsteadOfSystemName() {
        let builtin = display(name: "内建视网膜显示器", isBuiltin: true)
        XCTAssertEqual(builtin.displayLabel(locale: english), "Built-in Display")
        XCTAssertEqual(builtin.displayLabel(locale: chinese), "内建显示器")
        XCTAssertEqual(builtin.name, "内建视网膜显示器", "系统原名仍保留在快照里")
    }

    /// 外接屏的名字是厂商写进 EDID 的产品名，属专有名词，任何语言下都原样显示。
    func testExternalDisplayKeepsEDIDProductName() {
        let external = display(name: "DELL U2723QE", isBuiltin: false)
        XCTAssertEqual(external.displayLabel(locale: english), "DELL U2723QE")
        XCTAssertEqual(external.displayLabel(locale: chinese), "DELL U2723QE")
        XCTAssertNil(display(name: nil, isBuiltin: false).displayLabel(locale: english))
    }

    private func display(name: String?, isBuiltin: Bool) -> DisplaySnapshot {
        DisplaySnapshot(displayID: 1, name: name, pixelWidth: 2940, pixelHeight: 1912,
                        refreshRateHz: 60, linkRateLabel: nil, isMain: true, isBuiltin: isBuiltin)
    }
}
