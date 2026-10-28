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
    /// 已按合同充电，合同达到（或无法与）充电器最高档（比较）
    case chargingWithinContract
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

    /// 充电器可用档位上限 W：端口 PD 档位表（`options`，充电器上报的全部 fixed 档）里的最大功率。
    ///
    /// `options` 是充电器**广告的能力表**，与"协商结果"是两回事：
    /// - `options` 的最大值 = **充电器**能提供的最高档（如 20V×5A = 100W）；
    /// - `winning` = 选中了哪一档 PDO，其 `Max Current` 是**该档上限**，不是 RDO 里
    ///   实际请求的电流——所以它既不能当"合同"，也不能当"线缆能力"的证据。
    ///
    /// 拿 `winning` 冒充"充电器能力"会让判定自我循环（拿选中的档跟它自己比，
    /// 于是"线缆受限"永不触发），多线时更会拿**别的线**的档位当充电器能力而误报。
    ///
    /// **保守原则**：只有恰好一个端口带 `powerSource` 时才返回档位表上限；多端口时返回 nil
    /// —— 避免跨充电器误判。
    public static func adapterMaxPDOWatts(ports: [USBCPortSnapshot]) -> Double? {
        let portsWithPowerSource = ports.compactMap { $0.powerSource }
        guard portsWithPowerSource.count == 1 else { return nil }
        return portsWithPowerSource[0].options.map(\.maxPowerMW).max().map { Double($0) / 1000 }
    }

    /// - Parameters:
    ///   - power: 当前电源快照
    ///   - adapterMaxWatts: **充电器**可用档位上限 W（`adapterMaxPDOWatts(ports:)`）；
    ///     无端口控制器数据（老机型）时传 nil，跳过"线缆受限"分支。
    ///   - locale: 文案生成使用的语言；不传时跟随系统区域设置（CLI/旧调用点行为不变）。
    ///
    /// **合同只认 `power.pdContract`。** 端口控制器的 `winning` 是充电器广告的一个
    /// PDO，其 `Max Current` 是**该档上限**而非 RDO 里实际请求的电流，拿它当合同会把
    /// "充电器能给的"说成"这根线谈成的"。
    ///
    /// **也不比较"实际功率"与合同。** macOS 不提供端口级实测功率，电池侧功率
    /// （`PowerSnapshot.watts`）还要扣掉整机功耗，拿它跟合同比会得出"充电器没满档"
    /// 的错误结论——那只是电池没吃满而已。
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

        // 合同 < 适配器档位上限：线缆（或电池状态）可能压低了协商档位。
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

        // 合同已到（或无法与）充电器最高档（比较）。
        // 只说"协商到了哪一档"——输出功率没有端口级读数，断言不了。
        if let adapterMaxWatts {
            return ChargingDiagnostics(
                verdict: .chargingWithinContract,
                summary: KitLocalization.string(
                    template: "已协商到充电器最高档 %@W", locale: locale,
                    args: KitLocalization.fixedFraction(adapterMaxWatts, digits: 0)),
                detail: KitLocalization.string(
                    "实际充电功率取决于电池状态与整机功耗（macOS 不提供端口级功率读数）", locale: locale)
            )
        }
        return ChargingDiagnostics(
            verdict: .chargingWithinContract,
            summary: KitLocalization.string("已按 PD 合同充电", locale: locale),
            detail: KitLocalization.string(
                "没有端口档位数据，无法比较充电器上限；实际功率取决于电池状态与整机功耗", locale: locale)
        )
    }

    // MARK: 端口一句话头条

    /// 生成端口头条，如 "USB-C · PD 档位 100W · 被动线缆 · 5A（≤100W） · USB4/雷雳可用"。
    /// 无任何可说内容时返回 nil。
    ///
    /// **只讲本端口直读的事实**：充电功率是整机量（电池侧），多线时无法归属到某一条，
    /// 放进每端口的头条会让所有端口显示同一个数字。这里只报该端口选中的 PD 档位。
    public static func portHeadline(port: USBCPortSnapshot?,
                                    locale: Locale = .current) -> String? {
        guard let port else { return nil }
        var parts: [String] = []
        if let portType = port.portType {
            parts.append(portType)
        }

        // winning 是选中的 PDO，`Max Current` 是该档上限——措辞用"PD 档位"，
        // 不说"合同"（合同电流在 AdapterDetails.Current 里，是整机侧的量）。
        if let winning = port.powerSource?.winning {
            parts.append(KitLocalization.string(template: "PD 档位 %@W", locale: locale,
                                                args: String(Int(winning.watts.rounded()))))
        }

        if let eMarker = port.eMarker {
            if let description = eMarker.productTypeDescription {
                parts.append(eMarkerDescription(description, locale: locale))
            }
            if let rating = eMarker.decodedCurrentRating, rating != .reserved {
                parts.append(rating.label(locale: locale))
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
