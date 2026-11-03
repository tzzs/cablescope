import Foundation
import XCTest
@testable import CableKit

/// `ChargingOverviewBuilder` 测试：桌面小组件与主窗口共用的充电概览组装规则。
///
/// 这组规则原先住在 `CableScopeWidget` target 里（Xcode-only，不在 `Package.swift` 中，
/// `swift test` 覆盖不到），已下沉到 CableKit 的纯函数。
final class ChargingOverviewTests: XCTestCase {
    // MARK: - 辅助构造

    private func makePower(isCharging: Bool = true,
                           externalConnected: Bool = true,
                           volts: Int = 20_000,
                           milliamps: Int = 5_000,
                           batteryVolts: Int = 12_000,
                           percent: Double? = 80) -> PowerSnapshot {
        PowerSnapshot(isCharging: isCharging,
                      batteryPercent: percent,
                      adapterVoltageMV: volts,
                      batteryAmperageMA: milliamps,
                      batteryVoltageMV: batteryVolts,
                      pdContract: PDContract(voltageMV: volts, currentMA: milliamps),
                      adapterDescription: nil,
                      cycleCount: nil,
                      externalConnected: externalConnected)
    }

    private func makePort(portID: String,
                          portType: String? = "USB-C",
                          winningWatts: Int? = nil,
                          supportsTB4: Bool = false) -> USBCPortSnapshot {
        let phase = winningWatts.map {
            PDOPhase(voltageMV: 20_000, maxCurrentMA: 5_000, maxPowerMW: $0 * 1000, uuid: "u-\(portID)")
        }
        let powerSource = phase.map {
            PDOPortPowerSnapshot(sourceName: "USB-PD", options: [$0], winning: $0)
        }
        return USBCPortSnapshot(portID: portID,
                                controllerClass: "AppleHPMInterfaceType10",
                                portType: portType,
                                plugOrientation: nil,
                                isActive: true,
                                hasActiveCable: true,
                                connectionCount: 1,
                                transportsSupported: supportsTB4 ? ["CIO", "USB2", "USB3"] : ["USB2", "USB3"],
                                transportsProvisioned: ["USB2"],
                                featuresEnabled: [],
                                eMarker: nil,
                                partner: nil,
                                powerSource: powerSource)
    }

    // MARK: - 无数据

    /// 电源与端口都读不到 → 占位概览（`hasData == false`）。
    func testNoPowerAndNoPortsYieldsPlaceholder() {
        let overview = ChargingOverviewBuilder.build(power: nil, ports: [])
        XCTAssertFalse(overview.hasData)
        XCTAssertNil(overview.watts)
        XCTAssertNil(overview.topPortHeadline)
        XCTAssertTrue(overview.portHeadlines.isEmpty)
    }

    /// 只有电源、没有端口：仍算有数据（能显示充电功率与电量）。
    func testPowerOnlyCountsAsData() {
        let overview = ChargingOverviewBuilder.build(power: makePower(), ports: [])
        XCTAssertTrue(overview.hasData)
        XCTAssertEqual(overview.watts, 60, "电池侧功率 = 12V × 5A，不是适配器 20V × 5A")
        XCTAssertEqual(overview.batteryPercent, 80)
        XCTAssertTrue(overview.isCharging)
        XCTAssertTrue(overview.externalConnected)
        XCTAssertNil(overview.topPortHeadline)
    }

    /// 只有端口、没有电源：也算有数据（能显示端口头条）。
    func testPortsOnlyCountsAsData() {
        let overview = ChargingOverviewBuilder.build(power: nil, ports: [makePort(portID: "Port-USB-C@1")])
        XCTAssertTrue(overview.hasData)
        XCTAssertFalse(overview.isCharging)
        XCTAssertFalse(overview.externalConnected)
        XCTAssertEqual(overview.portHeadlines.count, 1)
    }

    // MARK: - 功率语义

    /// 充电中且读数 > 0 → 报功率。
    func testChargingWattsReportedWhenCharging() {
        let overview = ChargingOverviewBuilder.build(power: makePower(volts: 20_000, milliamps: 4_900), ports: [])
        XCTAssertEqual(overview.watts ?? 0, 12.0 * 4.9, accuracy: 0.01)
    }

    /// 保温暂停（isCharging == false）→ 不报功率，但「已接通」仍为 true。
    /// 这是 App 与 Widget 都必须遵守的区分：判断"是否插电"用 externalConnected，
    /// 不是 isCharging。
    func testPausedChargingReportsNoWattsButStillExternal() {
        let overview = ChargingOverviewBuilder.build(power: makePower(isCharging: false), ports: [])
        XCTAssertNil(overview.watts)
        XCTAssertTrue(overview.externalConnected)
        XCTAssertFalse(overview.isCharging)
    }

    /// 未接通电源 → 功率为 nil。
    func testNotConnectedReportsNoWatts() {
        let overview = ChargingOverviewBuilder.build(
            power: makePower(isCharging: false, externalConnected: false), ports: [])
        XCTAssertNil(overview.watts)
        XCTAssertFalse(overview.externalConnected)
    }

    // MARK: - 端口头条

    /// 置顶头条优先取**正在收电**（winning）的端口，而不是列表里的第一个。
    func testTopHeadlinePrefersChargingPort() {
        let idle = makePort(portID: "Port-USB-C@1", portType: "空闲口")
        let charging = makePort(portID: "Port-USB-C@2", portType: "收电口", winningWatts: 100)
        let overview = ChargingOverviewBuilder.build(power: makePower(), ports: [idle, charging])

        XCTAssertEqual(overview.portHeadlines.count, 2)
        // 置顶的应是收电那条，而不是数组里的第一个。
        let top = overview.topPortHeadline
        XCTAssertNotNil(top)
        XCTAssertTrue(top!.contains("收电口"), "置顶头条应是收电端口：\(String(describing: top))")
    }

    /// 没有 winning 档时，置顶退回首条头条。
    func testTopHeadlineFallsBackToFirstWhenNoPortIsCharging() {
        let first = makePort(portID: "Port-USB-C@1", portType: "第一口")
        let second = makePort(portID: "Port-USB-C@2", portType: "第二口")
        let overview = ChargingOverviewBuilder.build(power: nil, ports: [first, second])

        XCTAssertEqual(overview.portHeadlines.count, 2)
        XCTAssertNotNil(overview.topPortHeadline, "有端口时置顶头条不应为 nil")
        XCTAssertEqual(overview.topPortHeadline, overview.portHeadlines.first)
    }

    /// 各端口的 PD 协商档功率取最大值。
    func testWinningPDOWattsTakesMaximumAcrossPorts() {
        let low = makePort(portID: "Port-USB-C@1", winningWatts: 20)
        let high = makePort(portID: "Port-USB-C@2", winningWatts: 100)
        let overview = ChargingOverviewBuilder.build(power: makePower(), ports: [low, high])
        XCTAssertEqual(overview.winningPDOWatts, 100)
    }

    /// 没有协商档的端口不参与最大值计算。
    func testWinningPDOWattsNilWhenNoPortNegotiated() {
        let overview = ChargingOverviewBuilder.build(power: makePower(), ports: [makePort(portID: "Port-USB-C@1")])
        XCTAssertNil(overview.winningPDOWatts)
    }

    // MARK: - 充电功率辅助函数

    /// `chargingWatts` 的三条边界：负读数（保温暂停时电池侧微小放电）为 nil。
    func testChargingWattsRejectsNegativeReadout() {
        XCTAssertNil(ChargingOverviewBuilder.chargingWatts(makePower(milliamps: -200)))
        XCTAssertNil(ChargingOverviewBuilder.chargingWatts(nil))
        XCTAssertEqual(ChargingOverviewBuilder.chargingWatts(makePower(milliamps: 1_000)), 12)
    }
}
