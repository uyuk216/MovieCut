import XCTest
import CoreText
@testable import MovieCutCore

/// フォントの太さ(ウェイト)指定。weight 未設定のときは従来(bold フラグ)のままであること。
final class FontWeightTests: XCTestCase {
    private func decode(_ json: String) throws -> TextStyle {
        try JSONDecoder().decode(TextStyle.self, from: Data(json.utf8))
    }

    func testWeightRoundTrips() throws {
        var s = TextStyle(); s.weight = "black"
        let data = try JSONEncoder().encode(s)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"weight\":\"black\""))
        let back = try JSONDecoder().decode(TextStyle.self, from: data)
        XCTAssertEqual(back.weight, "black")
        XCTAssertEqual(back.weightValue, .black)
        XCTAssertEqual(back, s)
    }

    func testOldJSONWithoutWeightKeepsBoldMeaning() throws {
        let a = try decode(##"{"shadow":{"color":"#000000"},"align":"left"}"##)
        XCTAssertNil(a.weight); XCTAssertNil(a.weightValue)
        XCTAssertTrue(a.boldOrDefault)
        let b = try decode(#"{"bold":false}"#)
        XCTAssertNil(b.weight)
        XCTAssertFalse(b.boldOrDefault)
    }

    func testInvalidWeightIsDroppedByNormalized() {
        var s = TextStyle(); s.weight = "ultra-fat"
        XCTAssertNil(s.weightValue)
        XCTAssertNil(s.normalized.weight)
        var ok = TextStyle(); ok.weight = "heavy"
        XCTAssertEqual(ok.normalized.weight, "heavy")
    }

    func testWeightOnlyStyleIsNotEmptyAndAffectsLine() {
        var s = TextStyle(); s.weight = "light"
        XCTAssertFalse(s.isEmpty)
        XCTAssertTrue(s.affectsLine)
        XCTAssertTrue(s.lineKey.contains("|wlight"))
        XCTAssertFalse(TextStyle().affectsLine)
    }

    func testLineKeyWithoutWeightIsUnchanged() {
        let s = TextStyle()
        XCTAssertEqual(s.lineKey, "0.0|false|true")
        XCTAssertFalse(s.lineKey.contains("w"))
        var sh = TextStyle(); sh.shadow = TextStyle.Shadow(); sh.bold = false
        XCTAssertEqual(sh.lineKey, "0.0|false|false|s#000000,4.0,4.0,6.0,0.7")
    }

    func testWeightValuesAndLabels() {
        let v = TextStyle.FontWeight.allCases.map(\.value)
        XCTAssertEqual(v, [-0.6, -0.4, 0.0, 0.23, 0.3, 0.4, 0.56, 0.8])
        XCTAssertEqual(TextStyle.FontWeight.black.label, "黒")
        XCTAssertEqual(TextStyle.FontWeight.allCases.count, 8)
    }

    func testFontCacheKeysDoNotCollideAcrossWeights() {
        let a = TextCache.font(name: "Helvetica Neue", size: 40, bold: true, weight: .light)
        let b = TextCache.font(name: "Helvetica Neue", size: 40, bold: true, weight: .black)
        XCTAssertNotEqual(a.faceKey, b.faceKey)
        let la = TextCache.layout(a, font: "Helvetica Neue", line: "Aあ")
        let lb = TextCache.layout(b, font: "Helvetica Neue", line: "Aあ")
        XCTAssertNotEqual(la.width, lb.width)
    }

    /// weight 未設定の解決は、従来の「CTFontCreateWithName + 太字トレイト変換 → 無ければ疑似」と同じ。
    func testNoWeightResolutionMatchesLegacy() {
        for name in ["Helvetica Neue", "Hiragino Maru Gothic ProN", "Rounded Mplus 1c"] {
            let size = 48.0
            let base = CTFontCreateWithName(name as CFString, CGFloat(size), nil)
            let boldCT = CTFontCreateCopyWithSymbolicTraits(base, CGFloat(size), nil, .traitBold, .traitBold)
            let hasBold = boldCT.map { CTFontGetSymbolicTraits($0).contains(.traitBold) } ?? false
            let t = TextFont(name: name, size: size, bold: true)
            XCTAssertEqual(t.synthetic, !hasBold, name)
            XCTAssertEqual(CTFontCopyPostScriptName(t.ct) as String, CTFontCopyPostScriptName(hasBold ? boldCT! : base) as String, name)
            XCTAssertFalse(t.regular); XCTAssertEqual(t.faceKey, "")
            let r = TextFont(name: name, size: size, bold: false)
            XCTAssertFalse(r.synthetic); XCTAssertTrue(r.regular)
            XCTAssertEqual(CTFontCopyPostScriptName(r.ct) as String, CTFontCopyPostScriptName(base) as String, name)
        }
    }

    func testWeightResolutionPicksDistinctFaces() throws {
        let family = "Rounded Mplus 1c"
        let probe = CTFontCreateWithName(family as CFString, 40, nil)
        try XCTSkipUnless((CTFontCopyFamilyName(probe) as String).caseInsensitiveCompare(family) == .orderedSame, "\(family) が無い環境")
        func ps(_ w: TextStyle.FontWeight) -> String {
            let f = TextFont(name: family, size: 40, bold: false, weight: w)
            XCTAssertFalse(f.synthetic)
            return CTFontCopyPostScriptName(f.ct) as String
        }
        // この family は Bold(0.4) / ExtraBold(0.6) / Black(0.8) の3本で、Regular の面が無い。
        // 指定値は「最も近い太さ」に解決される。regular は面が無いので Bold、black(0.8) は Black、heavy(0.56) は ExtraBold になる(仕様の確定)。
        let regular = ps(.regular), bold = ps(.bold), heavy = ps(.heavy), black = ps(.black)
        XCTAssertEqual(regular, bold)
        XCTAssertEqual(bold, "RoundedMplus1c-Bold")
        XCTAssertEqual(heavy, "RoundedMplus1c-ExtraBold")
        XCTAssertEqual(black, "RoundedMplus1c-Black")
        // bold フラグはウェイト指定のときは見ない
        let withBoldFlag = TextFont(name: family, size: 40, bold: true, weight: .black)
        XCTAssertEqual(CTFontCopyPostScriptName(withBoldFlag.ct) as String, black)
    }
}
