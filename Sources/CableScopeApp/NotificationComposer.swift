import CableKit
import Foundation

/// 一条待投递通知的文案（纯值，不含投递动作）。
struct NotificationDraft: Equatable {
    let title: String
    let body: String
    /// 通知中心按它分组——同一个端口的插拔/提升归在一起，而不是平铺一长串。
    let thread: String
}

/// 通知文案组装（纯函数，不碰 `UNUserNotificationCenter`）。
///
/// 为什么单独抽出来：原实现把"决定说什么"和"怎么投递"写在一个方法里，
/// 结果文案规则（端口头条 → 速率 → "端口无设备"的三级兜底、断开时的端口名、
/// 充电时的 PD 合同功率）完全无法单测——它们是产品可见的规则，改错了不会有任何报错。
/// 拆开之后，规则在这里被逐条钉住，`NotificationController` 只负责开关、限流与投递。
enum NotificationComposer {

    /// 组装某条事件的通知文案。
    ///
    /// - Returns: 文案草案；会话在快照里找不到时返回 nil（调用方此时**不应**消耗限流窗口，
    ///   否则一次查不到会话的失败也会占掉这个方向 5 秒的额度）。
    static func draft(for event: CableNotificationEvent,
                       snapshot: CableSnapshot,
                       previousSessions: [String: CableSession],
                       port: (CableSession) -> USBCPortSnapshot?,
                       locale: Locale) -> NotificationDraft? {
        switch event {
        case .sessionConnected(let sessionID):
            guard let session = snapshot.sessions.first(where: { $0.id == sessionID }) else { return nil }
            let template = AppLocalization.string("已连接 %@", locale: locale)
            return NotificationDraft(
                title: String(format: template, session.shortPortLabel(locale: locale)),
                body: connectBody(session: session, port: port(session), locale: locale),
                thread: sessionID)

        case .sessionDisconnected(let sessionID):
            // 断开时会话已不在当前快照里，端口名要取上一轮的记录；
            // 取不到就只说"线缆已断开"，不编造端口。
            let body: String
            if let session = previousSessions[sessionID] {
                let template = AppLocalization.string("%@ 已断开", locale: locale)
                body = String(format: template, session.shortPortLabel(locale: locale))
            } else {
                body = ""
            }
            return NotificationDraft(title: AppLocalization.string("线缆已断开", locale: locale),
                                     body: body,
                                     thread: sessionID)

        case .chargingStarted:
            return NotificationDraft(title: AppLocalization.string("开始充电", locale: locale),
                                     body: chargingBody(snapshot.power, locale: locale),
                                     thread: "charging")

        case .chargingStopped:
            return NotificationDraft(title: AppLocalization.string("已停止充电", locale: locale),
                                     body: "",
                                     thread: "charging")

        case .usbSpeedUpgraded(let sessionID, let speed):
            guard let session = snapshot.sessions.first(where: { $0.id == sessionID }) else { return nil }
            let template = AppLocalization.string("%@ 协商速率提升", locale: locale)
            return NotificationDraft(
                title: String(format: template, session.shortPortLabel(locale: locale)),
                body: "\(speed.generation) \(speed.label)",
                thread: sessionID)

        case .ratingUpgraded(let sessionID, let dimension):
            guard let session = snapshot.sessions.first(where: { $0.id == sessionID }) else { return nil }
            let template = AppLocalization.string("%@ 线缆评级提升", locale: locale)
            return NotificationDraft(
                title: String(format: template, session.shortPortLabel(locale: locale)),
                body: dimension.localizedDescription(locale: locale),
                thread: sessionID)
        }
    }

    /// 开始充电时附上 PD 合同功率（比电池侧功率稳定：后者随电池状态与系统负载波动）。
    private static func chargingBody(_ power: PowerSnapshot?, locale: Locale) -> String {
        guard let contract = power?.pdContract else { return "" }
        let template = AppLocalization.string("PD 合同 %lldW", locale: locale)
        return String(format: template, Int(contract.watts.rounded()))
    }

    /// 连接后的正文：端口头条 → 会话最高速率 → "端口无设备"，三级兜底。
    private static func connectBody(session: CableSession,
                                    port: USBCPortSnapshot?,
                                    locale: Locale) -> String {
        var parts: [String] = []
        if let headline = DiagnosticsEngine.portHeadline(port: port, locale: locale) {
            parts.append(headline)
        } else if let speed = session.topUSBSpeed {
            parts.append("\(speed.generation) \(speed.label)")
        } else if session.deviceCount == 0 {
            parts.append(AppLocalization.string("端口无设备", locale: locale))
        }
        return parts.joined(separator: " · ")
    }
}

extension RatingUpgradeDimension {
    func localizedDescription(locale: Locale) -> String {
        switch self {
        case .fiveAmpConfirmed: return AppLocalization.string("首次确认至少支持 5A", locale: locale)
        case .displayLink: return AppLocalization.string("显示器链路规格提升", locale: locale)
        }
    }
}
