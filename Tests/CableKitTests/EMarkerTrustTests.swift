import XCTest
@testable import CableKit

/// EMarkerTrust.assess 的注入式测试：覆盖全部信号分支与叠加组合，不依赖 bundle 资源。
final class EMarkerTrustTests: XCTestCase {
    /// 构造 e-marker 快照的辅助：vdos 需要 ≥4 个对象才解码 Cable VDO。
    private func makeEMarker(vendorID: UInt32?,
                             productTypeDescription: String? = nil,
                             cableVDO: UInt32? = nil) -> EMarkerSnapshot {
        var vdos: [UInt32] = [0, 0, 0]
        if let cableVDO { vdos.append(cableVDO) }
        return EMarkerSnapshot(vendorID: vendorID,
                               productID: nil,
                               productType: nil,
                               productTypeDescription: productTypeDescription,
                               vdos: vdos)
    }

    private func knownDirectory() -> VendorDirectory {
        VendorDirectory(entries: [0x05AC: "Apple, Inc.", 0x0BDA: "Realtek Semiconductor Corp."])
    }

    /// vendorID == nil → missingIdentity（即使有其他身份字段也不足以核对厂商）。
    func testMissingIdentityWhenVendorIDAbsent() {
        let eMarker = makeEMarker(vendorID: nil, productTypeDescription: "Passive Cable")
        let notes = EMarkerTrust.assess(eMarker, vendorDirectory: knownDirectory())
        XCTAssertEqual(notes, [.missingIdentity])
    }

    /// vendorID == 0 → zeroVendorID（不误报 unknownVendorID，也不做真伪判决）。
    func testZeroVendorID() {
        let eMarker = makeEMarker(vendorID: 0)
        let notes = EMarkerTrust.assess(eMarker, vendorDirectory: knownDirectory())
        XCTAssertEqual(notes, [.zeroVendorID])
    }

    /// vendorID 非零但目录查不到 → unknownVendorID。
    func testUnknownVendorID() {
        let eMarker = makeEMarker(vendorID: 0x9999)
        let notes = EMarkerTrust.assess(eMarker, vendorDirectory: knownDirectory())
        XCTAssertEqual(notes, [.unknownVendorID])
    }

    /// vendorID 非零且在目录中 → 无身份类信号。
    func testKnownVendorIDProducesNoNote() {
        let eMarker = makeEMarker(vendorID: 0x05AC)
        let notes = EMarkerTrust.assess(eMarker, vendorDirectory: knownDirectory())
        XCTAssertTrue(notes.isEmpty, "正常身份不应产生可信度提示")
    }

    /// 传入 nil 目录（如调用方禁用查库）：非零 VID 不产生 unknownVendorID。
    func testNilDirectorySkipsUnknownCheck() {
        let eMarker = makeEMarker(vendorID: 0x9999)
        let notes = EMarkerTrust.assess(eMarker, vendorDirectory: nil)
        XCTAssertTrue(notes.isEmpty)
    }

    /// Cable VDO bits[6:5] = 3（保留值）→ reservedCurrentRating。
    func testReservedCurrentRating() {
        let eMarker = makeEMarker(vendorID: 0x05AC, cableVDO: 3 << 5)
        let notes = EMarkerTrust.assess(eMarker, vendorDirectory: knownDirectory())
        XCTAssertEqual(notes, [.reservedCurrentRating])
    }

    /// Cable VDO bits[6:5] = 2（5A）→ 无评级信号（正常档位）。
    func testFiveAmpRatingProducesNoNote() {
        let eMarker = makeEMarker(vendorID: 0x0BDA, cableVDO: 2 << 5)
        let notes = EMarkerTrust.assess(eMarker, vendorDirectory: knownDirectory())
        XCTAssertTrue(notes.isEmpty)
    }

    /// 叠加：未收录 VID + 保留评级 → 两个信号按稳定顺序叠加。
    func testUnknownVendorCombinedWithReservedRating() {
        let eMarker = makeEMarker(vendorID: 0x9999, cableVDO: 3 << 5)
        let notes = EMarkerTrust.assess(eMarker, vendorDirectory: VendorDirectory(entries: [:]))
        XCTAssertEqual(notes, [.unknownVendorID, .reservedCurrentRating])
    }

    /// 措辞红线：summary 不得含"假/劣质/山寨"等判决词，也不得为空。
    func testSummariesUseCautiousWording() {
        for note in EMarkerTrustNote.allCases {
            XCTAssertFalse(note.summary.isEmpty, "\(note.rawValue) 的 summary 不应为空")
            for banned in ["假", "劣质", "山寨", "counterfeit", "fake"] {
                XCTAssertFalse(note.summary.lowercased().contains(banned),
                               "\(note.rawValue) 的措辞不得含判决词「\(banned)」")
            }
        }
        XCTAssertEqual(EMarkerTrustNote.allCases.count, 4, "M3 共四类信号")
    }
}
