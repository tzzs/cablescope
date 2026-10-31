import XCTest
@testable import CableKit

/// PowerService 的 IORegistry 属性解析测试。
/// 样例结构来自真机 `ioreg -r -c AppleSmartBattery`（macOS 26，Apple Silicon）。
final class PowerParsingTests: XCTestCase {
    /// 真机回归样例：顶层没有 AdapterVoltage，适配器电压只能回退到 AdapterDetails；
    /// 电池侧功率（12.6V×2.014A≈25W）与 PD 合同（20V×5A=100W）语义分离。
    func testRealShapedPropertiesInstantaneousVsContract() {
        let props: [String: Any] = [
            "ExternalConnected": true,
            "IsCharging": true,
            "Amperage": 2014,
            "Voltage": 12597,
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
        XCTAssertEqual(power.batteryAmperageMA, 2014, "电池电流取顶层 Amperage")
        XCTAssertEqual(power.batteryVoltageMV, 12597, "电池电压取顶层 Voltage")
        XCTAssertEqual(power.watts ?? 0, 12.597 * 2.014, accuracy: 0.01,
                       "电池侧功率 = 电池电压 × 电池电流（不能拿适配器电压混乘）")
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
            "Voltage": 12000,
            "AdapterDetails": ["AdapterVoltage": 20000, "Current": 5000],
        ]
        let power = PowerParsing.parse(props: props)
        XCTAssertEqual(power.adapterVoltageMV, 9000)
        XCTAssertEqual(power.watts ?? 0, 36, accuracy: 0.01, "电池 12V × 3A")
        XCTAssertEqual(power.pdContract?.watts ?? 0, 100, accuracy: 0.01, "合同仍取 AdapterDetails")
    }

    /// AdapterDetails 缺失时不得用顶层 Amperage（瞬时抽流）拼出"假合同"：
    /// 合同电流只认 AdapterDetails.Current，读不到就没有合同。
    func testMissingAdapterDetailsProducesNoContract() {
        let props: [String: Any] = [
            "ExternalConnected": true,
            "IsCharging": true,
            "AdapterVoltage": 20000,
            "Amperage": 5000,
            "Voltage": 12000,
        ]
        let power = PowerParsing.parse(props: props)

        XCTAssertEqual(power.adapterVoltageMV, 20000)
        XCTAssertEqual(power.batteryAmperageMA, 5000)
        XCTAssertEqual(power.watts ?? 0, 60, accuracy: 0.01, "电池 12V × 5A")
        XCTAssertNil(power.pdContract, "没有协商电流读数时不得构造合同（瞬时抽流 ≠ 合同）")
    }

    /// AdapterDetails 存在但缺 Current 键：同样不构造合同。
    func testAdapterDetailsWithoutCurrentProducesNoContract() {
        let props: [String: Any] = [
            "ExternalConnected": true,
            "IsCharging": true,
            "Amperage": 2014,
            "Voltage": 12597,
            "AdapterDetails": ["AdapterVoltage": 20000, "Watts": 100, "Description": "pd charger"],
        ]
        let power = PowerParsing.parse(props: props)

        XCTAssertEqual(power.adapterVoltageMV, 20000)
        XCTAssertEqual(power.watts ?? 0, 12.597 * 2.014, accuracy: 0.01)
        XCTAssertNil(power.pdContract, "缺 Current 键时不得用顶层 Amperage 兜底成合同")
        XCTAssertEqual(power.adapterDescription, "pd charger")
    }

    /// 顶层 AdapterVoltage 可作合同电压回退（它是适配器输出电压，语义上算合同电压），
    /// 但合同电流仍必须来自 AdapterDetails.Current。
    func testTopLevelAdapterVoltageAsContractVoltageFallback() {
        let props: [String: Any] = [
            "ExternalConnected": true,
            "IsCharging": true,
            "AdapterVoltage": 20000,
            "Amperage": 4000,
            "Voltage": 12000,
            "AdapterDetails": ["Current": 5000],
        ]
        let power = PowerParsing.parse(props: props)

        XCTAssertEqual(power.pdContract?.voltageMV, 20000)
        XCTAssertEqual(power.pdContract?.currentMA, 5000)
        XCTAssertEqual(power.pdContract?.watts ?? 0, 100, accuracy: 0.01)
    }

    func testUnpluggedClearsAdapterInfo() {
        let props: [String: Any] = [
            "ExternalConnected": false,
            "IsCharging": false,
            "Amperage": -1200, // 电池放电为负值
            "Voltage": 12000,
            "AdapterVoltage": 0,
            "CurrentCapacity": 70,
            "MaxCapacity": 100,
        ]
        let power = PowerParsing.parse(props: props)

        XCTAssertFalse(power.isCharging)
        XCTAssertFalse(power.externalConnected)
        XCTAssertNil(power.adapterVoltageMV)
        XCTAssertNil(power.batteryAmperageMA)
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
            "Voltage": 12597,
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
        XCTAssertEqual(power.batteryAmperageMA, -540)
        XCTAssertEqual(power.watts ?? 0, 12.597 * -0.54, accuracy: 0.01,
                       "电池侧功率保留原始负值，由 UI 层决定是否展示")
        XCTAssertEqual(power.pdContract?.watts ?? 0, 100, accuracy: 0.01, "保温时 PD 合同依然可读")
    }

    func testStringBooleanTolerance() {
        // ioreg 文本输出中布尔表现为 Yes/No，解析需兜底
        let props: [String: Any] = [
            "ExternalConnected": "Yes",
            "IsCharging": "Yes",
            "Amperage": 1000,
            "Voltage": 12000,
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
