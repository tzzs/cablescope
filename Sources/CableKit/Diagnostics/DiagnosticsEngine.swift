import Foundation

// MARK: - 充电 / 速率归因诊断（纯函数，可单测）
//
// 目标：把"数字"翻译成"解释"——为什么充电慢、这条线现在能干什么。
// 话术红线（Docs/03）：凡涉及线缆规格的结论必须用"可能/至少"，不得虚构认证信息。

/// 充电瓶颈归因结论
public enum ChargingBottleneck: Equatable, Sendable {
    /// 未接通电源（使用电池）
    case notConnected
    /// 已接通但未充电（优化充电暂停 / 电池保温 / 读数缺失）
    case paused
    /// 充电器正按合同满档输出
    case adapterMax
    /// 实际抽取低于合同（电池接近充满 / 系统限流）
    case machineDrawingLess
    /// 合同低于适配器可用档位——线缆可能限制了协商档位
    case cableLikelyLimited
    /// 数据不足，无法归因
    case unknown
}

/// 充电诊断结果：结论 + 一句话解释 + 可选补充
public struct ChargingDiagnostics: Equatable, Sendable {
    public let verdict: ChargingBottleneck
    public let summary: String
    public let detail: String?

    public init(verdict: ChargingBottleneck, summary: String, detail: String? = nil) {
        self.verdict = verdict
        self.summary = summary
        self.detail = detail
    }
}

public enum DiagnosticsEngine {
    // MARK: 充电归因

    /// - Parameters:
    ///   - power: 当前电源快照
    ///   - adapterMaxWatts: 端口 PD 档位表里可用的最大功率（WinningPowerSourceOption）；
    ///     无端口控制器数据（老机型）时传 nil，跳过"线缆受限"分支。
    ///   - locale: 文案生成使用的语言；不传时跟随系统区域设置（CLI/旧调用点行为不变）。
    public static func diagnoseCharging(power: PowerSnapshot?,
                                        adapterMaxWatts: Double?,
                                        locale: Locale = .current) -> ChargingDiagnostics {
        guard let power else {
            return ChargingDiagnostics(verdict: .unknown,
                summary: KitLocalization.string("暂无电源数据", locale: locale))
        }
        guard power.externalConnected else {
            return ChargingDiagnostics(verdict: .notConnected,
                summary: KitLocalization.string("未接通电源，使用电池", locale: locale))
        }
        guard power.isCharging else {
            return ChargingDiagnostics(
                verdict: .paused,
                summary: KitLocalization.string("已接通电源，未在充电", locale: locale),
                detail: KitLocalization.string("常见于优化充电暂停或电池保温（电量接近充满时系统主动放缓）", locale: locale)
            )
        }

        guard let contractWatts = power.pdContract?.watts, contractWatts > 0 else {
            return ChargingDiagnostics(verdict: .unknown,
                summary: KitLocalization.string("正在充电（合同读数缺失）", locale: locale))
        }
        let realWatts = power.watts ?? 0

        // 合同 < 适配器档位上限：线缆（或电池状态）可能压低了协商档位。
        // 先于"满档输出"判断——机器正按合同满抽、但合同本身低于适配器能力时，问题在线缆而非充电器。
        if let adapterMaxWatts, contractWatts < adapterMaxWatts * 0.95 {
            return ChargingDiagnostics(
                verdict: .cableLikelyLimited,
                summary: KitLocalization.string(
                    template: "PD 合同 %@W 低于适配器可用档 %@W", locale: locale,
                    args: KitLocalization.fixedFraction(contractWatts, digits: 0),
                          KitLocalization.fixedFraction(adapterMaxWatts, digits: 0)),
                detail: KitLocalization.string("线缆可能限制了协商档位（未标 5A 的线无法请求大电流档）；电池状态也可能影响，仅供参考", locale: locale)
            )
        }

        // 实际输出 ≈ 合同：充电器已满档输出。
        if realWatts >= contractWatts * 0.9 {
            return ChargingDiagnostics(
                verdict: .adapterMax,
                summary: KitLocalization.string("充电器正按合同满档输出", locale: locale),
                detail: KitLocalization.string(
                    template: "当前 %@W ≈ PD 合同 %@W", locale: locale,
                    args: KitLocalization.fixedFraction(realWatts, digits: 1),
                          KitLocalization.fixedFraction(contractWatts, digits: 0))
            )
        }

        return ChargingDiagnostics(
            verdict: .machineDrawingLess,
            summary: KitLocalization.string(
                template: "实际抽取 %@W，低于合同 %@W", locale: locale,
                args: KitLocalization.fixedFraction(realWatts, digits: 1),
                      KitLocalization.fixedFraction(contractWatts, digits: 0)),
            detail: KitLocalization.string("电池接近充满或系统在限流，属正常现象", locale: locale)
        )
    }

    // MARK: 端口一句话头条

    /// 生成端口头条，如 "USB-C · ⚡98.7W · 被动线缆 · 5A（≤100W） · USB4/雷雳可用"。
    /// 无任何可说内容时返回 nil。
    public static func portHeadline(port: USBCPortSnapshot?, power: PowerSnapshot?,
                                    locale: Locale = .current) -> String? {
        guard let port else { return nil }
        var parts: [String] = []
        if let portType = port.portType {
            parts.append(portType)
        }

        if power?.isCharging == true, let watts = power?.watts, watts > 0 {
            parts.append(KitLocalization.string(template: "⚡%@W", locale: locale,
                                                args: KitLocalization.fixedFraction(watts, digits: 1)))
        } else if let winning = port.powerSource?.winning {
            parts.append(KitLocalization.string(template: "合同 %@W", locale: locale,
                                                args: String(Int(winning.watts.rounded()))))
        }

        if let eMarker = port.eMarker {
            if let description = eMarker.productTypeDescription {
                parts.append(eMarkerDescription(description, locale: locale))
            }
            if let rating = eMarker.decodedCurrentRating, rating != .reserved {
                parts.append(rating.label)
            }
        }

        if port.supportsThunderboltUSB4 {
            parts.append(KitLocalization.string("USB4/雷雳可用", locale: locale))
        }

        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    /// Apple 的产品类型描述是英文（"Passive Cable"），展示层统一翻译成当前语言。
    public static func eMarkerDescription(_ raw: String, locale: Locale = .current) -> String {
        switch raw.lowercased() {
        case "passive cable": return KitLocalization.string("被动线缆", locale: locale)
        case "active cable": return KitLocalization.string("主动线缆", locale: locale)
        case let v where v.contains("epr"): return KitLocalization.string("EPR 线缆", locale: locale)
        default: return raw
        }
    }
}
