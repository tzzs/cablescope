import XCTest
@testable import CableKit

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
            adapterAmperageMA: external ? realAmperageMA : nil,
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
                                                        adapterMaxWatts: 100)
        XCTAssertEqual(result.verdict, .paused)
        XCTAssertEqual(result.summary, "已接通电源，未在充电")
    }

    func testAdapterMaxOutput() {
        // 实时 ≈ 合同（20V×5A=100W 合同，实时 95W+）。
        let result = DiagnosticsEngine.diagnoseCharging(
            power: power(isCharging: true, external: true, realAmperageMA: 4_800),
            adapterMaxWatts: 100
        )
        XCTAssertEqual(result.verdict, .adapterMax)
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

    func testMachineDrawingLessWithoutAdapterMax() {
        // 无端口控制器数据（老机型）：实时 40W < 合同 100W，不能断言是线缆问题。
        let result = DiagnosticsEngine.diagnoseCharging(
            power: power(isCharging: true, external: true, realAmperageMA: 2_000),
            adapterMaxWatts: nil
        )
        XCTAssertEqual(result.verdict, .machineDrawingLess)
    }

    func testUnknownWithoutPowerData() {
        XCTAssertEqual(DiagnosticsEngine.diagnoseCharging(power: nil, adapterMaxWatts: nil).verdict, .unknown)
    }

    func testUnknownWhenContractMissing() {
        let noContract = PowerSnapshot(isCharging: true, batteryPercent: 50,
                                       adapterVoltageMV: 20_000, adapterAmperageMA: 2_000,
                                       pdContract: nil, adapterDescription: nil, cycleCount: nil,
                                       externalConnected: true)
        XCTAssertEqual(DiagnosticsEngine.diagnoseCharging(power: noContract, adapterMaxWatts: 100).verdict,
                       .unknown)
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
        let chargingPower = power(isCharging: true, external: true, realAmperageMA: 4_900)

        let headline = DiagnosticsEngine.portHeadline(port: port, power: chargingPower)
        XCTAssertNotNil(headline)
        XCTAssertTrue(headline?.contains("USB-C") ?? false)
        XCTAssertTrue(headline?.contains("⚡") ?? false)
        XCTAssertTrue(headline?.contains("被动线缆") ?? false)
        XCTAssertTrue(headline?.contains("5A") ?? false)
        XCTAssertTrue(headline?.contains("USB4/雷雳") ?? false)
    }

    func testEMarkerDescriptionLocalization() {
        XCTAssertEqual(DiagnosticsEngine.eMarkerDescription("Passive Cable"), "被动线缆")
        XCTAssertEqual(DiagnosticsEngine.eMarkerDescription("Active Cable"), "主动线缆")
        XCTAssertEqual(DiagnosticsEngine.eMarkerDescription("EPR Cable"), "EPR 线缆")
        XCTAssertEqual(DiagnosticsEngine.eMarkerDescription("Unknown Thing"), "Unknown Thing")
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
