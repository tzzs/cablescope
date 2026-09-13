import Foundation

// MARK: - e-marker 可信度信号（M3）
//
// 对直读的 e-marker 身份数据做「观察层」标记：零 VID、未收录 VID、保留位评级、缺身份。
// 产品红线（Docs/03 第六节 / Docs/04 M3 节）：只提示"看起来不寻常"，不得输出
// "假线 / 劣质 / 山寨" 之类的真伪判决——零 VID 在低价但合规的线缆上并不罕见。

/// e-marker 的可信度信号（观察层标记，非真伪结论）。
public enum EMarkerTrustNote: String, Codable, Sendable, CaseIterable {
    /// e-marker 上报厂商 ID 为 0（未上报）
    case zeroVendorID
    /// 厂商 ID 非零，但不在内置厂商目录中
    case unknownVendorID
    /// Cable VDO 的电流评级位段为保留值（3），未标定 3A/5A
    case reservedCurrentRating
    /// 未上报厂商身份（无 VID），无法核对厂商
    case missingIdentity

    /// 面向用户的一句话说明（中文、谨慎措辞，不做真伪判决）。
    public var summary: String {
        switch self {
        case .zeroVendorID:
            return "e-marker 未上报厂商 ID（部分低价线缆常见）"
        case .unknownVendorID:
            return "厂商 ID 不在已知厂商列表中"
        case .reservedCurrentRating:
            return "电流评级为保留值，未标定 3A/5A 能力"
        case .missingIdentity:
            return "e-marker 未提供厂商身份信息，无法核对厂商"
        }
    }
}

/// e-marker 可信度评估（纯函数）。
public enum EMarkerTrust {
    /// 对一份 e-marker 快照评估可信度信号。
    ///
    /// 规则（互不排斥，可叠加返回，顺序稳定：身份信号在前、评级信号在后）：
    /// - `vendorID == nil` → `.missingIdentity`；
    /// - `vendorID == 0` → `.zeroVendorID`；
    /// - `vendorID` 非零但厂商目录查不到 → `.unknownVendorID`（目录为 nil 时不做该检查）；
    /// - `decodedCurrentRating == .reserved` → `.reservedCurrentRating`。
    /// 正常身份 + 正常评级返回空数组。
    public static func assess(_ eMarker: EMarkerSnapshot,
                              vendorDirectory: VendorDirectory? = .shared) -> [EMarkerTrustNote] {
        var notes: [EMarkerTrustNote] = []
        switch eMarker.vendorID {
        case .none:
            notes.append(.missingIdentity)
        case .some(0):
            notes.append(.zeroVendorID)
        case .some(let vendorID):
            if let vendorDirectory, vendorDirectory.name(forVendorID: vendorID) == nil {
                notes.append(.unknownVendorID)
            }
        }
        if eMarker.decodedCurrentRating == .reserved {
            notes.append(.reservedCurrentRating)
        }
        return notes
    }
}
