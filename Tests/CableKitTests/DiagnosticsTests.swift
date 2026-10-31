import XCTest
@testable import CableKit

private extension Character {
    /// 粗略判定：落在 CJK 统一表意文字区块即视为中文字符（够用于"英文档不应残留中文"的断言）。
    var isChineseCharacter: Bool {
        unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    }
}

/// DiagnosticsEngine 的归因规则测试（表驱动覆盖每个分支）。
final class DiagnosticsTests: XCTestCase {

    private func power(isCharging: Bool,
                       external: Bool,
                       realVoltageMV: Int? = 20_000,
                       realAmperageMA: Int? = 5_000,
                       contractVoltageMV: Int? = 20_000,
                       contractAmperageMA: Int? = 5_000) -> PowerSnapshot {
        PowerSnapshot(
            isCharging: isCharging,
            batteryPercent: 50,
            adapterVoltageMV: external ? realVoltageMV : nil,
            batteryAmperageMA: external ? realAmperageMA : nil,
            pdContract: external ? PDContract(voltageMV: contractVoltageMV ?? 0,
                                              currentMA: contractAmperageMA ?? 0) : nil,
            adapterDescription: "pd charger",
            cycleCount: nil,
            externalConnected: external
        )
    }

    // MARK: 充电归因

    func testNotConnected() {
        let result = DiagnosticsEngine.diagnoseCharging(power: power(isCharging: false, external: false),
                                                        adapterMaxWatts: nil)
        XCTAssertEqual(result.verdict, .notConnected)
    }

    func testPausedWhileConnected() {
        // 优化充电暂停：已接通但 IsCharging=false。
        let result = DiagnosticsEngine.diagnoseCharging(power: power(isCharging: false, external: true),
                                                        adapterMaxWatts: 100,
                                                        locale: Locale(identifier: "zh-Hans"))
        XCTAssertEqual(result.verdict, .paused)
        // 显式传 zh-Hans，断言不受 CI 运行环境系统 locale 影响。
        XCTAssertEqual(result.summary, "已接通电源，未在充电")
    }

    /// 英文档下应产出非空、不含中文字符的文案（确认翻译条目确实存在，不会漏译静默回退成中文 key）。
    func testSummariesHaveEnglishTranslations() {
        let english = Locale(identifier: "en")
        let cases: [ChargingDiagnostics] = [
            DiagnosticsEngine.diagnoseCharging(power: nil, adapterMaxWatts: nil, locale: english),
            DiagnosticsEngine.diagnoseCharging(power: power(isCharging: false, external: false),
                                               adapterMaxWatts: nil, locale: english),
            DiagnosticsEngine.diagnoseCharging(power: power(isCharging: false, external: true),
                                               adapterMaxWatts: 100, locale: english),
            DiagnosticsEngine.diagnoseCharging(power: power(isCharging: true, external: true, realAmperageMA: 4_800),
                                               adapterMaxWatts: 100, locale: english),
            DiagnosticsEngine.diagnoseCharging(
                power: power(isCharging: true, external: true, realAmperageMA: 3_250,
                             contractVoltageMV: 20_000, contractAmperageMA: 3_250),
                adapterMaxWatts: 100, locale: english),
            DiagnosticsEngine.diagnoseCharging(power: power(isCharging: true, external: true, realAmperageMA: 2_000),
                                               adapterMaxWatts: nil, locale: english),
        ]
        for diagnostics in cases {
            XCTAssertFalse(diagnostics.summary.isEmpty)
            XCTAssertFalse(diagnostics.summary.contains(where: \.isChineseCharacter),
                           "英文档下 summary 不应含中文字符：\(diagnostics.summary)")
            if let detail = diagnostics.detail {
                XCTAssertFalse(detail.contains(where: \.isChineseCharacter),
                               "英文档下 detail 不应含中文字符：\(detail)")
            }
        }
    }

    func testContractAtAdapterMaxTier() {
        // 合同 100W 已到充电器最高档（20V×5A）。
        let result = DiagnosticsEngine.diagnoseCharging(
            power: power(isCharging: true, external: true),
            adapterMaxWatts: 100
        )
        XCTAssertEqual(result.verdict, .chargingWithinContract)
    }

    func testCableLikelyLimitedRequiresAdapterMax() {
        // 合同 65W 低于适配器 100W 档 ⇒ 线缆可能受限。
        let result = DiagnosticsEngine.diagnoseCharging(
            power: power(isCharging: true, external: true,
                         realAmperageMA: 3_250,
                         contractVoltageMV: 20_000, contractAmperageMA: 3_250),
            adapterMaxWatts: 100
        )
        XCTAssertEqual(result.verdict, .cableLikelyLimited)
    }

    /// 没有充电器档位表（老机型）时只报"已按合同充电"，不编造"满档输出"结论。
    ///
    /// 旧实现会拿电池侧功率与合同比较，得出"实际抽取低于合同"；那不是充电器的输出
    /// 功率（macOS 不提供端口级读数），结论站不住。
    func testNoAdapterTierDataStillReportsContractOnly() {
        let result = DiagnosticsEngine.diagnoseCharging(
            power: power(isCharging: true, external: true, realAmperageMA: 2_000),
            adapterMaxWatts: nil
        )
        XCTAssertEqual(result.verdict, .chargingWithinContract)
    }

    func testUnknownWithoutPowerData() {
        XCTAssertEqual(DiagnosticsEngine.diagnoseCharging(power: nil, adapterMaxWatts: nil).verdict, .unknown)
    }

    func testUnknownWhenContractMissing() {
        let noContract = PowerSnapshot(isCharging: true, batteryPercent: 50,
                                       adapterVoltageMV: 20_000, batteryAmperageMA: 2_000,
                                       pdContract: nil, adapterDescription: nil, cycleCount: nil,
                                       externalConnected: true)
        XCTAssertEqual(DiagnosticsEngine.diagnoseCharging(power: noContract, adapterMaxWatts: 100).verdict,
                       .unknown)
    }

    // MARK: 端口侧参数语义（充电器能力 vs 实际协商档）

    /// 构造一个带 PD 档位表的端口。
    ///
    /// - Parameters:
    ///   - optionWatts: 充电器上报的档位表（每档的 W）。
    ///   - winningWatts: 实际协商到的档（nil = 未协商）。
    ///   - hasPowerSource: 空闲端口根本没有 `powerSource`（`IOPortFeaturePowerSource`
    ///     只挂在带电源的端口上），传 false 构造这种情形。
    private func makePort(portID: String,
                          optionWatts: [Double],
                          winningWatts: Double?,
                          hasPowerSource: Bool = true) -> USBCPortSnapshot {
        func phase(_ watts: Double, _ uuid: String) -> PDOPhase {
            PDOPhase(voltageMV: 20_000, maxCurrentMA: Int(watts * 1000 / 20), maxPowerMW: Int(watts * 1000),
                     uuid: uuid)
        }
        let options = optionWatts.enumerated().map { phase($0.element, "opt-\($0.offset)") }
        let winning = winningWatts.flatMap { watts -> PDOPhase? in
            options.first { Double($0.maxPowerMW) / 1000 == watts }
        }
        let powerSource: PDOPortPowerSnapshot? = hasPowerSource
            ? PDOPortPowerSnapshot(sourceName: "USB-PD", options: options, winning: winning)
            : nil
        return USBCPortSnapshot(
            portID: portID, controllerClass: "AppleHPMInterfaceType10",
            portType: "USB-C", plugOrientation: nil, isActive: true, hasActiveCable: true,
            connectionCount: 1,
            transportsSupported: ["CIO"], transportsProvisioned: ["CIO"], featuresEnabled: [],
            eMarker: nil, partner: nil, powerSource: powerSource)
    }

    /// 充电器能力取**档位表的最大值**，不是当前协商档。
    ///
    /// 这条是"线缆受限"判定能否成立的前提：充电器能给 100W、这根线只谈到 60W，
    /// 只有拿 100W（档位表上限）去比才判得出来。拿 60W（协商档）去比就是自己跟自己比。
    func testAdapterMaxPDOWattsUsesOptionTableNotWinningPhase() {
        let port = makePort(portID: "Port-USB-C@1", optionWatts: [60, 100], winningWatts: 60)
        XCTAssertEqual(DiagnosticsEngine.adapterMaxPDOWatts(ports: [port]), 100)
    }

    /// 没有档位表（无端口控制器数据）→ nil，不编造充电器能力。
    func testAdapterMaxPDOWattsNilWithoutPortData() {
        XCTAssertNil(DiagnosticsEngine.adapterMaxPDOWatts(ports: []))
    }

    /// **两个**端口都带 power source → nil（跨充电器无法归属，宁可不猜）。
    ///
    /// 笔记本一边被 30W 充电器供电、一边用另一个 USB-C 口给硬盘供电时，
    /// 两个端口都会报档位表。此时若跨端口取 max，就会拿 100W 那条的上限去比
    /// 30W 充电器的合同 → 误报"线缆受限"，而真正的限制来自那个小充电器。
    func testAdapterMaxPDOWattsNilWithTwoPoweredPorts() {
        let a = makePort(portID: "Port-USB-C@1", optionWatts: [30], winningWatts: 30)
        let b = makePort(portID: "Port-USB-C@2", optionWatts: [60, 100], winningWatts: 60)
        XCTAssertNil(DiagnosticsEngine.adapterMaxPDOWatts(ports: [a, b]))
    }

    /// 一个端口带 power source、另一个没有 → 仍能用前者（空闲口不参与）。
    func testAdapterMaxPDOWattsIgnoresPortsWithoutPowerSource() {
        let charging = makePort(portID: "Port-USB-C@2", optionWatts: [60, 100], winningWatts: 60)
        let idle = makePort(portID: "Port-USB-C@1", optionWatts: [], winningWatts: nil, hasPowerSource: false)
        XCTAssertEqual(DiagnosticsEngine.adapterMaxPDOWatts(ports: [idle, charging]), 100)
    }

    /// 端口选中的 PD 档位**不是合同**：没有 `pdContract` 时仍必须说"读数缺失"。
    ///
    /// `WinningPowerSourceOption` 选中的是充电器广告的一个 PDO，`Max Current` 是该档
    /// 上限而非 RDO 里实际请求的电流；3A 线也可能选中 20V/5A 那个 PDO。拿它当合同
    /// 会把"充电器能给的"说成"这根线谈成的"。
    func testWinningPhaseIsNotUsedAsContract() {
        let noContract = PowerSnapshot(isCharging: true, batteryPercent: 50,
                                       adapterVoltageMV: 20_000, batteryAmperageMA: 2_000,
                                       pdContract: nil, adapterDescription: nil, cycleCount: nil,
                                       externalConnected: true)
        let port = makePort(portID: "Port-USB-C@1", optionWatts: [60, 100], winningWatts: 60)
        let result = DiagnosticsEngine.diagnoseCharging(
            power: noContract,
            adapterMaxWatts: DiagnosticsEngine.adapterMaxPDOWatts(ports: [port]))
        XCTAssertEqual(result.verdict, .unknown)
    }

    /// 端到端回归：单端口、充电器档位表到 100W、合同只谈到 60W → 判出"线缆受限"。
    ///
    /// 这条正是旧实现判不出来的场景——旧实现把"当前协商档"当充电器能力，
    /// 于是拿 60W 跟 60W 比，"线缆受限"永远不触发。
    func testSinglePortCableLimitedIsDetectedEndToEnd() {
        let port = makePort(portID: "Port-USB-C@1", optionWatts: [60, 100], winningWatts: 60)
        let contract60 = PowerSnapshot(isCharging: true, batteryPercent: 50,
                                       adapterVoltageMV: 20_000, batteryAmperageMA: 3_000,
                                       pdContract: PDContract(voltageMV: 20_000, currentMA: 3_000),
                                       adapterDescription: nil, cycleCount: nil,
                                       externalConnected: true)
        let result = DiagnosticsEngine.diagnoseCharging(
            power: contract60,
            adapterMaxWatts: DiagnosticsEngine.adapterMaxPDOWatts(ports: [port]))
        XCTAssertEqual(result.verdict, .cableLikelyLimited)
    }

    // MARK: 端口头条

    func testPortHeadlineCombinesSegments() {
        let port = USBCPortSnapshot(
            portID: "Port-USB-C@1", controllerClass: "AppleHPMInterfaceType10",
            portType: "USB-C", plugOrientation: 1, isActive: true, hasActiveCable: true,
            connectionCount: 3,
            transportsSupported: ["CC", "CIO"], transportsProvisioned: ["CC"],
            featuresEnabled: ["Power In"],
            eMarker: EMarkerSnapshot(vendorID: 0, productID: 0, productType: 3,
                                     productTypeDescription: "Passive Cable",
                                     vdos: [0x18000000, 0, 0, 0x00084042]),
            partner: nil,
            powerSource: PDOPortPowerSnapshot(
                sourceName: "USB-PD",
                options: [PDOPhase(voltageMV: 20_000, maxCurrentMA: 5_000, maxPowerMW: 100_000, uuid: "B")],
                winning: PDOPhase(voltageMV: 20_000, maxCurrentMA: 5_000, maxPowerMW: 100_000, uuid: "B"))
        )
        let headline = DiagnosticsEngine.portHeadline(port: port,
                                                       locale: Locale(identifier: "zh-Hans"))
        XCTAssertNotNil(headline)
        XCTAssertTrue(headline?.contains("USB-C") ?? false)
        // 端口头条只报本端口的 PD 档位，不掺整机电池侧功率（多线时会张张卡一样）。
        XCTAssertTrue(headline?.contains("PD 档位 100W") ?? false, headline ?? "")
        XCTAssertFalse(headline?.contains("⚡") ?? true, "端口头条不应再出现整机功率：\(headline ?? "")")
        XCTAssertTrue(headline?.contains("被动线缆") ?? false)
        XCTAssertTrue(headline?.contains("5A") ?? false)
        XCTAssertTrue(headline?.contains("USB4/雷雳") ?? false)
    }

    func testEMarkerDescriptionLocalization() {
        let zh = Locale(identifier: "zh-Hans")
        XCTAssertEqual(DiagnosticsEngine.eMarkerDescription("Passive Cable", locale: zh), "被动线缆")
        XCTAssertEqual(DiagnosticsEngine.eMarkerDescription("Active Cable", locale: zh), "主动线缆")
        XCTAssertEqual(DiagnosticsEngine.eMarkerDescription("EPR Cable", locale: zh), "EPR 线缆")
        XCTAssertEqual(DiagnosticsEngine.eMarkerDescription("Unknown Thing", locale: zh), "Unknown Thing")
    }

    func testEMarkerDescriptionEnglish() {
        let en = Locale(identifier: "en")
        XCTAssertEqual(DiagnosticsEngine.eMarkerDescription("Passive Cable", locale: en), "Passive cable")
        XCTAssertEqual(DiagnosticsEngine.eMarkerDescription("Active Cable", locale: en), "Active cable")
        XCTAssertEqual(DiagnosticsEngine.eMarkerDescription("EPR Cable", locale: en), "EPR cable")
    }

    // MARK: Cable VDO 解码边界

    func testCableVDODecodingBoundaries() {
        func marker(_ cableVDO: UInt32) -> EMarkerSnapshot {
            EMarkerSnapshot(vendorID: 0, productID: 0, productType: nil,
                            productTypeDescription: nil,
                            vdos: [0x18000000, 0, 0, cableVDO])
        }
        XCTAssertEqual(marker(0x00000000).decodedSpeed, .usb2)
        XCTAssertEqual(marker(0x00000001).decodedSpeed, .usb32Gen1)
        XCTAssertEqual(marker(0x00000003).decodedSpeed, .usb4Gen3)
        XCTAssertEqual(marker(0x00000004).decodedSpeed, .usb4Gen4)
        XCTAssertEqual(marker(0x00000000).decodedCurrentRating, .usbDefault)
        XCTAssertEqual(marker(0x00000020).decodedCurrentRating, .threeAmp, "bits[6:5]=01 ⇒ 3A")
        XCTAssertEqual(marker(0x00000040).decodedCurrentRating, .fiveAmp, "bits[6:5]=10 ⇒ 5A")

        // VDO 不足 4 个（无 Cable VDO）时不猜测。
        let shortMarker = EMarkerSnapshot(vendorID: 0, productID: 0, productType: nil,
                                          productTypeDescription: nil,
                                          vdos: [0x18000000, 0, 0])
        XCTAssertNil(shortMarker.decodedSpeed)
        XCTAssertNil(shortMarker.decodedCurrentRating)
    }
}
