import XCTest
@testable import CableKit

/// PowerService 的 IORegistry 属性解析测试。
/// 样例结构来自真机 `ioreg -r -c AppleSmartBattery`（macOS 26，Apple Silicon）。
final class PowerParsingTests: XCTestCase {
    /// 真机回归样例：顶层没有 AdapterVoltage，瞬时电压只能回退到 AdapterDetails；
    /// 瞬时功率（20V×2.014A≈40W）与 PD 合同（20V×5A=100W）语义分离。
    func testRealShapedPropertiesInstantaneousVsContract() {
        let props: [String: Any] = [
            "ExternalConnected": true,
            "IsCharging": true,
            "Amperage": 2014,
            "CurrentCapacity": 80,
            "MaxCapacity": 100,
            "CycleCount": 40,
            "AdapterDetails": [
                "AdapterVoltage": 20000,
                "Current": 5000,
                "Watts": 100,
                "Description": "pd charger",
            ],
        ]
        let power = PowerParsing.parse(props: props)

        XCTAssertTrue(power.isCharging)
        XCTAssertTrue(power.externalConnected)
        XCTAssertEqual(power.adapterVoltageMV, 20000, "顶层无 AdapterVoltage 时应回退到 AdapterDetails")
        XCTAssertEqual(power.adapterAmperageMA, 2014, "瞬时电流取顶层 Amperage")
        XCTAssertEqual(power.watts ?? 0, 20.0 * 2.014, accuracy: 0.01, "瞬时功率 = 电压 × 实际抽流")
        XCTAssertEqual(power.pdContract?.voltageMV, 20000)
        XCTAssertEqual(power.pdContract?.currentMA, 5000, "PD 合同电流取 AdapterDetails.Current")
        XCTAssertEqual(power.pdContract?.watts ?? 0, 100, accuracy: 0.01)
        XCTAssertEqual(power.adapterDescription, "pd charger")
        XCTAssertEqual(power.cycleCount, 40)
        XCTAssertEqual(power.batteryPercent ?? 0, 80, accuracy: 0.01)
    }

    func testTopLevelAdapterVoltagePreferredWhenPresent() {
        // 老系统顶层有 AdapterVoltage 时优先使用
        let props: [String: Any] = [
            "ExternalConnected": true,
            "IsCharging": true,
            "AdapterVoltage": 9000,
            "Amperage": 3000,
            "AdapterDetails": ["AdapterVoltage": 20000, "Current": 5000],
        ]
        let power = PowerParsing.parse(props: props)
        XCTAssertEqual(power.adapterVoltageMV, 9000)
        XCTAssertEqual(power.watts ?? 0, 27, accuracy: 0.01)
        XCTAssertEqual(power.pdContract?.watts ?? 0, 100, accuracy: 0.01, "合同仍取 AdapterDetails")
    }

    func testUnpluggedClearsAdapterInfo() {
        let props: [String: Any] = [
            "ExternalConnected": false,
            "IsCharging": false,
            "Amperage": -1200, // 电池放电为负值
            "AdapterVoltage": 0,
            "CurrentCapacity": 70,
            "MaxCapacity": 100,
        ]
        let power = PowerParsing.parse(props: props)

        XCTAssertFalse(power.isCharging)
        XCTAssertFalse(power.externalConnected)
        XCTAssertNil(power.adapterVoltageMV)
        XCTAssertNil(power.adapterAmperageMA)
        XCTAssertNil(power.pdContract)
        XCTAssertNil(power.adapterDescription)
        XCTAssertEqual(power.batteryPercent ?? 0, 70, accuracy: 0.01)
    }

    func testChargingRequiresExternalConnected() {
        // IsCharging=true 但 ExternalConnected=false 的矛盾状态：以未充电为准
        let props: [String: Any] = [
            "ExternalConnected": false,
            "IsCharging": true,
        ]
        let power = PowerParsing.parse(props: props)
        XCTAssertFalse(power.isCharging)
        XCTAssertFalse(power.externalConnected)
    }

    /// 真机回归（2026-09-13）：电池保温/优化充电暂停时，插着电但 IsCharging=No、
    /// 顶层 Amperage 为负（电池侧微小放电）。UI 须据此显示"已接通电源"而非"未充电"。
    func testConnectedButPausedCharging() {
        let props: [String: Any] = [
            "ExternalConnected": true,
            "IsCharging": false,
            "Amperage": -540,
            "CurrentCapacity": 86,
            "MaxCapacity": 100,
            "AdapterDetails": [
                "AdapterVoltage": 20000,
                "Current": 5000,
                "Watts": 100,
                "Description": "pd charger",
            ],
        ]
        let power = PowerParsing.parse(props: props)

        XCTAssertFalse(power.isCharging, "暂停充电时不得到误报正在充电")
        XCTAssertTrue(power.externalConnected, "插电状态必须如实上报，UI 靠它区分已接通/未接通")
        XCTAssertEqual(power.adapterVoltageMV, 20000)
        XCTAssertEqual(power.adapterAmperageMA, -540)
        XCTAssertEqual(power.watts ?? 0, 20.0 * -0.54, accuracy: 0.01, "瞬时功率保留原始负值，由 UI 层决定是否展示")
        XCTAssertEqual(power.pdContract?.watts ?? 0, 100, accuracy: 0.01, "保温时 PD 合同依然可读")
    }

    func testStringBooleanTolerance() {
        // ioreg 文本输出中布尔表现为 Yes/No，解析需兜底
        let props: [String: Any] = [
            "ExternalConnected": "Yes",
            "IsCharging": "Yes",
            "Amperage": 1000,
            "AdapterDetails": ["AdapterVoltage": 5000, "Current": 3000],
        ]
        let power = PowerParsing.parse(props: props)
        XCTAssertTrue(power.isCharging)
        XCTAssertEqual(power.pdContract?.watts ?? 0, 15, accuracy: 0.01)
    }

    func testBatteryPercentClamped() {
        let props: [String: Any] = ["CurrentCapacity": 150, "MaxCapacity": 100]
        XCTAssertEqual(PowerParsing.batteryPercent(from: props) ?? 0, 100, accuracy: 0.01)
        let negative: [String: Any] = ["CurrentCapacity": -5, "MaxCapacity": 100]
        XCTAssertEqual(PowerParsing.batteryPercent(from: negative) ?? 0, 0, accuracy: 0.01)
        let zeroMax: [String: Any] = ["CurrentCapacity": 50, "MaxCapacity": 0]
        XCTAssertNotEqual(PowerParsing.batteryPercent(from: zeroMax) ?? -1, 0, "MaxCapacity=0 时不得除零（回退 IOPS 或 nil）")
    }
}
