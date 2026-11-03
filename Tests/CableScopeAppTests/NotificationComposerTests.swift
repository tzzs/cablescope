import CableKit
@testable import CableScopeApp
import XCTest

/// 通知文案组装（纯函数）的规则测试。
///
/// 这些规则是产品可见的：插上时正文说什么、断开时能不能说清是哪个口、
/// 充电时附不附 PD 合同功率。改错了不会有任何运行时报错，只能靠测试钉住。
final class NotificationComposerTests: XCTestCase {
    private let zh = Locale(identifier: "zh-Hans")
    private let en = Locale(identifier: "en")

    // MARK: - 连接

    func testConnectedDraftUsesSessionLabelAndThread() {
        let session = makeSession(id: "Port-USB-C@2")
        let draft = NotificationComposer.draft(for: .sessionConnected(sessionID: session.id),
                                              snapshot: makeSnapshot(sessions: [session]),
                                              previousSessions: [:],
                                              port: { _ in nil },
                                              locale: zh)

        XCTAssertEqual(draft?.title, "已连接 USB-C·@2")
        XCTAssertEqual(draft?.thread, session.id)
    }

    /// 会话不在快照里时组装不出文案——调用方据此**不消耗限流窗口**。
    func testConnectedDraftIsNilWhenSessionMissing() {
        let draft = NotificationComposer.draft(for: .sessionConnected(sessionID: "gone"),
                                              snapshot: makeSnapshot(sessions: []),
                                              previousSessions: [:],
                                              port: { _ in nil },
                                              locale: zh)
        XCTAssertNil(draft)
    }

    /// 连接正文的三级兜底：端口头条 → 会话最高速率 → "端口无设备"。
    func testConnectBodyPrefersPortHeadline() {
        let session = makeSession(id: "s", devices: [makeDevice(speed: 10_000_000_000)])
        let port = makePort(portID: "Port-USB-C@1", portType: "USB-C")

        let draft = NotificationComposer.draft(for: .sessionConnected(sessionID: session.id),
                                              snapshot: makeSnapshot(sessions: [session]),
                                              previousSessions: [:],
                                              port: { _ in port },
                                              locale: zh)

        XCTAssertEqual(draft?.body, "USB-C")
    }

    func testConnectBodyFallsBackToSessionTopSpeed() {
        let session = makeSession(id: "s", devices: [makeDevice(speed: 10_000_000_000)])

        let draft = NotificationComposer.draft(for: .sessionConnected(sessionID: session.id),
                                              snapshot: makeSnapshot(sessions: [session]),
                                              previousSessions: [:],
                                              port: { _ in nil },
                                              locale: zh)

        XCTAssertEqual(draft?.body, "USB 3.x Gen2 10 Gbps")
    }

    /// 没有任何设备也没有端口数据：明说"端口无设备"，而不是给一条空正文。
    func testConnectBodyFallsBackToNoDeviceMessage() {
        let session = makeSession(id: "s")

        let draft = NotificationComposer.draft(for: .sessionConnected(sessionID: session.id),
                                              snapshot: makeSnapshot(sessions: [session]),
                                              previousSessions: [:],
                                              port: { _ in nil },
                                              locale: zh)

        XCTAssertEqual(draft?.body, "端口无设备")
    }

    // MARK: - 断开

    /// 断开时会话已不在快照里，端口名取上一轮记录。
    func testDisconnectedDraftUsesPreviousSessionLabel() {
        let session = makeSession(id: "s")
        let draft = NotificationComposer.draft(for: .sessionDisconnected(sessionID: session.id),
                                              snapshot: makeSnapshot(sessions: []),
                                              previousSessions: [session.id: session],
                                              port: { _ in nil },
                                              locale: zh)

        XCTAssertEqual(draft?.title, "线缆已断开")
        XCTAssertEqual(draft?.body, "USB-C·@2 已断开")
    }

    /// 上一轮也没有记录时只说"线缆已断开"，不编造端口。
    func testDisconnectedDraftWithoutPreviousSessionHasEmptyBody() {
        let draft = NotificationComposer.draft(for: .sessionDisconnected(sessionID: "s"),
                                              snapshot: makeSnapshot(sessions: []),
                                              previousSessions: [:],
                                              port: { _ in nil },
                                              locale: zh)

        XCTAssertEqual(draft?.title, "线缆已断开")
        XCTAssertEqual(draft?.body, "")
    }

    // MARK: - 充电

    /// 开始充电时附上 PD 合同功率（比电池侧功率稳定）。
    func testChargingStartedDraftIncludesPDContractWatts() {
        let power = makePower(pdContract: PDContract(voltageMV: 20_000, currentMA: 5_000))
        let draft = NotificationComposer.draft(for: .chargingStarted,
                                              snapshot: makeSnapshot(sessions: [], power: power),
                                              previousSessions: [:],
                                              port: { _ in nil },
                                              locale: zh)

        XCTAssertEqual(draft?.title, "开始充电")
        XCTAssertEqual(draft?.body, "PD 合同 100W")
        XCTAssertEqual(draft?.thread, "charging")
    }

    /// 没有 PD 合同时不给功率数字——不拿电池侧读数冒充合同功率。
    func testChargingStartedDraftWithoutContractHasEmptyBody() {
        let draft = NotificationComposer.draft(for: .chargingStarted,
                                              snapshot: makeSnapshot(sessions: [], power: makePower(pdContract: nil)),
                                              previousSessions: [:],
                                              port: { _ in nil },
                                              locale: zh)

        XCTAssertEqual(draft?.body, "")
    }

    func testChargingStoppedDraftHasEmptyBody() {
        let draft = NotificationComposer.draft(for: .chargingStopped,
                                              snapshot: makeSnapshot(sessions: []),
                                              previousSessions: [:],
                                              port: { _ in nil },
                                              locale: zh)

        XCTAssertEqual(draft?.title, "已停止充电")
        XCTAssertEqual(draft?.body, "")
    }

    // MARK: - 速率与评级提升

    func testSpeedUpgradeDraftNamesTheSpeed() {
        let session = makeSession(id: "s")
        let draft = NotificationComposer.draft(for: .usbSpeedUpgraded(sessionID: session.id,
                                                                        to: USBSpeed(bitsPerSecond: 10_000_000_000)),
                                              snapshot: makeSnapshot(sessions: [session]),
                                              previousSessions: [:],
                                              port: { _ in nil },
                                              locale: zh)

        XCTAssertEqual(draft?.title, "USB-C·@2 协商速率提升")
        XCTAssertEqual(draft?.body, "USB 3.x Gen2 10 Gbps")
    }

    func testRatingUpgradeDraftUsesLowerBoundWording() {
        let session = makeSession(id: "s")
        let draft = NotificationComposer.draft(for: .ratingUpgraded(sessionID: session.id,
                                                                     dimension: .fiveAmpConfirmed),
                                              snapshot: makeSnapshot(sessions: [session]),
                                              previousSessions: [:],
                                              port: { _ in nil },
                                              locale: zh)

        // 产品红线：只能说"至少支持 5A"，不能说"5A e-marker 线"。
        XCTAssertEqual(draft?.body, "首次确认至少支持 5A")
        XCTAssertFalse(draft!.body.contains("e-marker"))
    }

    // MARK: - 英文界面

    /// 英文界面下文案必须是英文（漏翻会静默退回中文 key）。
    func testDraftsFollowRequestedLocale() {
        let session = makeSession(id: "s")
        let draft = NotificationComposer.draft(for: .sessionConnected(sessionID: session.id),
                                              snapshot: makeSnapshot(sessions: [session]),
                                              previousSessions: [:],
                                              port: { _ in nil },
                                              locale: en)

        XCTAssertEqual(draft?.title, "Connected USB-C·@2")
        XCTAssertNotNil(draft)
    }

    // MARK: - 夹具

    private func makeSession(id: String, devices: [USBDeviceSnapshot] = []) -> CableSession {
        CableSession(id: id, kind: .usb, physicalPortID: "Port-USB-C@2", portType: "USB-C",
                     usbDevices: devices)
    }

    private func makeDevice(speed: Int) -> USBDeviceSnapshot {
        USBDeviceSnapshot(registryID: 1, locationID: 0x14100000, productName: "SSD",
                          vendorName: nil, vendorID: nil, productID: nil, serialNumber: nil,
                          bcdUSB: nil, speed: USBSpeed(bitsPerSecond: speed))
    }

    private func makePort(portID: String, portType: String) -> USBCPortSnapshot {
        USBCPortSnapshot(portID: portID, controllerClass: "AppleHPMInterfaceType10", portType: portType,
                         plugOrientation: nil, isActive: true, hasActiveCable: true, connectionCount: nil,
                         transportsSupported: ["CC"], transportsProvisioned: ["CC"], featuresEnabled: [],
                         eMarker: nil, partner: nil, powerSource: nil)
    }

    private func makePower(pdContract: PDContract?) -> PowerSnapshot {
        PowerSnapshot(isCharging: true, batteryPercent: 70, adapterVoltageMV: 20_000,
                      batteryAmperageMA: 2_000, batteryVoltageMV: 12_000, pdContract: pdContract,
                      adapterDescription: nil, cycleCount: nil, externalConnected: true)
    }

    private func makeSnapshot(sessions: [CableSession], power: PowerSnapshot? = nil) -> CableSnapshot {
        CableSnapshot(usbDevices: [], power: power, displays: [], thunderboltDevices: [],
                     sessions: sessions)
    }
}
