import CableKit
@testable import CableScopeApp
import XCTest

/// 用真实 `CableMonitor` 对真机做一次性快照（同 `RealEnvironmentSmokeTests` 的哲学）：
/// 是否插着线缆不影响下面的断言，只验证 `MonitorViewModel` 派生状态之间的内部一致性，
/// 以及评级历史确实落到了注入路径（不触碰真实用户的
/// ~/Library/Application Support/CableScope/ratings.json）。
@MainActor
final class MonitorViewModelTests: XCTestCase {
    private var ratingsURL: URL!

    override func setUp() {
        super.setUp()
        ratingsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cablescope-test-ratings-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: ratingsURL)
        ratingsURL = nil
        super.tearDown()
    }

    func testInitialStateHasNoSnapshotOrSessions() {
        let viewModel = MonitorViewModel(monitor: CableMonitor(), ratingsURL: ratingsURL)

        XCTAssertNil(viewModel.snapshot)
        XCTAssertTrue(viewModel.sessions.isEmpty)
        XCTAssertNil(viewModel.selectedSession)
        XCTAssertFalse(viewModel.isRefreshing)
        // 注入路径尚不存在文件时，engine 从空白状态起步——不会读到真实用户的评级历史。
        XCTAssertEqual(viewModel.rating, CableRatingEngine().overallRating())
    }

    func testRefreshIngestsSnapshotAndPersistsToInjectedPath() async throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: ratingsURL.path))

        let viewModel = MonitorViewModel(monitor: CableMonitor(), ratingsURL: ratingsURL)
        viewModel.refresh()
        XCTAssertTrue(viewModel.isRefreshing, "refresh() 应同步置位 isRefreshing，再异步采集")

        try await waitUntil(seconds: 15) { !viewModel.isRefreshing }

        XCTAssertNotNil(viewModel.snapshot,
                        "真实 CableMonitor 的 snapshotNow() 不应返回 nil——无设备时也应降级为空快照而非失败")
        // 未显式选择会话时回退到第一根（或都为空）。
        XCTAssertEqual(viewModel.selectedSession?.id, viewModel.sessions.first?.id)
        // ingest 会在每次快照后保存一次评级历史；验证它确实落到了注入路径，而不是真实用户的
        // ratings.json（回归此前 init 里"加载走 canonical、保存走注入路径"的不一致问题）。
        XCTAssertTrue(FileManager.default.fileExists(atPath: ratingsURL.path))
    }

    func testDerivedSessionAndPowerStateFromInjectedSnapshot() {
        let viewModel = MonitorViewModel(monitor: CableMonitor(), ratingsURL: ratingsURL)
        let first = makeSession(id: "Port-USB-C@1", portID: "Port-USB-C@1")
        let second = makeSession(id: "Port-USB-C@2", portID: "Port-USB-C@2")
        let winning = PDOPhase(voltageMV: 20_000, maxCurrentMA: 5_000, maxPowerMW: 100_000, uuid: "winner")
        let nonWinning = PDOPhase(voltageMV: 5_000, maxCurrentMA: 3_000, maxPowerMW: 15_000, uuid: "base")
        let ports = [
            makePort(id: "Port-USB-C@1", options: [nonWinning], winning: nil),
            makePort(id: "Port-USB-C@2", options: [nonWinning, winning], winning: winning),
        ]
        let power = PowerSnapshot(isCharging: true, batteryPercent: 70, adapterVoltageMV: 20_000,
                                  batteryAmperageMA: 2_000, batteryVoltageMV: 12_000,
                                  pdContract: PDContract(voltageMV: 20_000, currentMA: 5_000),
                                  adapterDescription: nil, cycleCount: nil, externalConnected: true)
        let usb = USBDeviceSnapshot(registryID: 1, locationID: 0x14100000, productName: "SSD",
                                    vendorName: nil, vendorID: nil, productID: nil, serialNumber: nil,
                                    bcdUSB: nil, speed: USBSpeed(bitsPerSecond: 10_000_000_000))
        let link = DisplayPortLinkSnapshot(portID: "Port-USB-C@2", isActive: true, isTunneled: false,
                                           linkRateDescription: "8.1 Gbps (HBR3)", manufacturerName: "AOC",
                                           productName: "U27", productID: 9987, serialNumber: 10)
        let display = DisplaySnapshot(displayID: 7, name: "U27", pixelWidth: 3840, pixelHeight: 2160,
                                      refreshRateHz: 60, linkRateLabel: nil, isMain: true,
                                      vendorNumber: 1507, modelNumber: 9987, serialNumber: 10)
        let snapshot = CableSnapshot(usbDevices: [usb], power: power, displays: [display],
                                     thunderboltDevices: [], sessions: [first, second], ports: ports,
                                     displayPortLinks: [link])

        viewModel.ingest(snapshot)

        XCTAssertTrue(viewModel.isCharging)
        XCTAssertTrue(viewModel.isExternalConnected)
        XCTAssertEqual(viewModel.displayWatts ?? 0, 24, accuracy: 0.001)
        XCTAssertEqual(viewModel.topUSBSpeed?.bitsPerSecond, 10_000_000_000)
        XCTAssertEqual(viewModel.negotiatedPDOVoltageMV, 20_000)
        XCTAssertEqual(viewModel.selectedSession?.id, first.id)
        XCTAssertNil(viewModel.power(for: first))
        XCTAssertEqual(viewModel.power(for: second), power)
        XCTAssertEqual(viewModel.port(for: second)?.portID, second.physicalPortID)
        XCTAssertEqual(viewModel.displayLinks(for: second).first?.display?.displayID, 7)
        XCTAssertEqual(viewModel.activePDO?.winning, winning)
    }

    func testSessionSelectionNavigationAndDisconnectionFallback() {
        let viewModel = MonitorViewModel(monitor: CableMonitor(), ratingsURL: ratingsURL)
        let first = makeSession(id: "one", portID: "Port-USB-C@1")
        let second = makeSession(id: "two", portID: "Port-USB-C@2")
        let snapshot = makeSnapshot(sessions: [first, second])

        viewModel.ingest(snapshot)
        viewModel.selectAdjacentSession(offset: 1)
        XCTAssertEqual(viewModel.selectedSessionID, "two")
        viewModel.selectAdjacentSession(offset: 1)
        XCTAssertEqual(viewModel.selectedSessionID, "one")
        viewModel.selectAdjacentSession(offset: -1)
        XCTAssertEqual(viewModel.selectedSessionID, "two")

        viewModel.selectSession("missing")
        XCTAssertEqual(viewModel.selectedSession?.id, "one", "无效的显式选择回退到第一根")
        viewModel.ingest(makeSnapshot(sessions: [first]))
        XCTAssertEqual(viewModel.selectedSessionID, "one", "选中的会话拔除后自动选中剩余会话")
        XCTAssertNil(viewModel.port(for: first))
        XCTAssertTrue(viewModel.displayLinks(for: first).isEmpty)
    }

    func testEmptySessionNavigationAndFallbackPDOSelection() {
        let viewModel = MonitorViewModel(monitor: CableMonitor(), ratingsURL: ratingsURL)
        viewModel.ingest(makeSnapshot(sessions: []))
        viewModel.selectSession("stale")
        viewModel.selectAdjacentSession(offset: 1)
        XCTAssertEqual(viewModel.selectedSessionID, "stale", "空列表移动不应改写选择态")
        XCTAssertNil(viewModel.selectedSession)

        let first = makeSession(id: "one", portID: nil)
        let second = makeSession(id: "two", portID: nil)
        let shortList = PDOPhase(voltageMV: 5_000, maxCurrentMA: 3_000, maxPowerMW: 15_000, uuid: "a")
        let longList = PDOPhase(voltageMV: 9_000, maxCurrentMA: 3_000, maxPowerMW: 27_000, uuid: "b")
        viewModel.ingest(makeSnapshot(sessions: [first, second], ports: [
            makePort(id: "Port-USB-C@1", options: [shortList], winning: nil),
            makePort(id: "Port-USB-C@2", options: [shortList, longList], winning: nil),
        ]))
        XCTAssertEqual(viewModel.activePDO?.options.count, 2, "无 winning 档时选择档位最多的电源")
        XCTAssertNil(viewModel.chargingDiagnostics)
    }

    func testChargingDiagnosticsAndSessionRatingReflectSnapshot() {
        let viewModel = MonitorViewModel(monitor: CableMonitor(), ratingsURL: ratingsURL)
        let session = makeSession(id: "Port-USB-C@1", portID: "Port-USB-C@1")
        let winning = PDOPhase(voltageMV: 20_000, maxCurrentMA: 5_000, maxPowerMW: 100_000, uuid: "winner")
        let power = PowerSnapshot(isCharging: true, batteryPercent: 70, adapterVoltageMV: 20_000,
                                  batteryAmperageMA: 2_000, batteryVoltageMV: 12_000,
                                  pdContract: PDContract(voltageMV: 20_000, currentMA: 5_000),
                                  adapterDescription: nil, cycleCount: nil, externalConnected: true)

        viewModel.ingest(makeSnapshot(sessions: [session], ports: [
            makePort(id: "Port-USB-C@1", options: [winning], winning: winning),
        ], power: power))

        XCTAssertNotNil(viewModel.chargingDiagnostics, "有 PD 合同时应给出充电诊断")
        XCTAssertEqual(viewModel.negotiatedPDOVoltageMV, 20_000)
        XCTAssertNotNil(viewModel.rating(forSessionID: session.id), "评级引擎按会话 id 记录历史峰值")
        XCTAssertEqual(viewModel.rating(forSessionID: "不存在"), nil)
    }

    private func makeSession(id: String, portID: String?) -> CableSession {
        CableSession(id: id, kind: .usb, physicalPortID: portID, portType: portID == nil ? nil : "USB-C")
    }

    private func makePort(id: String, options: [PDOPhase], winning: PDOPhase?) -> USBCPortSnapshot {
        USBCPortSnapshot(portID: id, controllerClass: "AppleHPMInterfaceType10", portType: "USB-C",
                         plugOrientation: nil, isActive: true, hasActiveCable: true, connectionCount: nil,
                         transportsSupported: ["CC"], transportsProvisioned: ["CC"], featuresEnabled: [],
                         eMarker: nil, partner: nil,
                         powerSource: PDOPortPowerSnapshot(sourceName: "USB-PD", options: options, winning: winning))
    }

    private func makeSnapshot(sessions: [CableSession],
                              ports: [USBCPortSnapshot] = [],
                              power: PowerSnapshot? = nil) -> CableSnapshot {
        CableSnapshot(usbDevices: [], power: power, displays: [], thunderboltDevices: [],
                     sessions: sessions, ports: ports)
    }

    // MARK: - 轮询等待（refresh() 不返回可 await 的句柄，用超时轮询代替）

    private func waitUntil(seconds: TimeInterval, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("等待超时（\(seconds)s）")
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
