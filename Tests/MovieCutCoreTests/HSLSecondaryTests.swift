import XCTest
import CoreGraphics
import CoreImage
@testable import MovieCutCore

/// HSL 範囲選択・マスク LUT・セカンダリ補正の数値テスト。
final class HSLSecondaryTests: XCTestCase {
    private func decode(_ data: Data) -> [Float] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    /// 赤(色相 0°)中心の選択。
    private var redSel: HSLSelection {
        HSLSelection(hueCenter: 0, hueWidth: 60, hueFeather: 40, satMin: 0.3, satMax: 1, satFeather: 0.1,
                     lumMin: 0.2, lumMax: 0.8, lumFeather: 0.1)
    }

    // MARK: weight

    func testWeightCenterIsOne() {
        XCTAssertEqual(redSel.weight(hueDegrees: 0, saturation: 0.8, lightness: 0.5), 1, accuracy: 1e-12)
        XCTAssertEqual(redSel.weight(r: 1, g: 0, b: 0), 1, accuracy: 1e-12)
        // 円周をまたぐ(350° は中心 0° から 10°)
        XCTAssertEqual(redSel.weight(hueDegrees: 350, saturation: 0.8, lightness: 0.5), 1, accuracy: 1e-12)
    }

    func testWeightFarHueIsZero() {
        XCTAssertEqual(redSel.weight(hueDegrees: 180, saturation: 0.8, lightness: 0.5), 0, accuracy: 1e-12)
        XCTAssertEqual(redSel.weight(r: 0, g: 0, b: 1), 0, accuracy: 1e-12)
    }

    func testWeightFeatherMidpointIsHalf() {
        // 内側の縁 = 30°、ぼかし 40° → 50° が中点
        XCTAssertEqual(redSel.weight(hueDegrees: 50, saturation: 0.8, lightness: 0.5), 0.5, accuracy: 1e-9)
        XCTAssertEqual(redSel.weight(hueDegrees: -50, saturation: 0.8, lightness: 0.5), 0.5, accuracy: 1e-9)
        XCTAssertEqual(redSel.weight(hueDegrees: 30, saturation: 0.8, lightness: 0.5), 1, accuracy: 1e-12)
        XCTAssertEqual(redSel.weight(hueDegrees: 70, saturation: 0.8, lightness: 0.5), 0, accuracy: 1e-12)
    }

    func testHardEdgeWhenFeatherZero() {
        let s = HSLSelection(hueCenter: 0, hueWidth: 60, hueFeather: 0, satMin: 0, satMax: 1, satFeather: 0, lumMin: 0, lumMax: 1, lumFeather: 0)
        XCTAssertEqual(s.weight(hueDegrees: 30, saturation: 0.5, lightness: 0.5), 1)
        XCTAssertEqual(s.weight(hueDegrees: 30.001, saturation: 0.5, lightness: 0.5), 0)
    }

    func testFullWidthIgnoresHue() {
        let s = HSLSelection(hueCenter: 123, hueWidth: 360, hueFeather: 0)
        for h in stride(from: 0.0, to: 360, by: 37) {
            XCTAssertEqual(s.weight(hueDegrees: h, saturation: 0.5, lightness: 0.5), 1, accuracy: 1e-12)
        }
    }

    func testSaturationAndLightnessOutsideAreZero() {
        XCTAssertEqual(redSel.weight(hueDegrees: 0, saturation: 0.05, lightness: 0.5), 0, accuracy: 1e-12)
        XCTAssertEqual(redSel.weight(hueDegrees: 0, saturation: 0.8, lightness: 0.95), 0, accuracy: 1e-12)
        XCTAssertEqual(redSel.weight(hueDegrees: 0, saturation: 0.8, lightness: 0.05), 0, accuracy: 1e-12)
        // 下限のぼかし中点
        XCTAssertEqual(redSel.weight(hueDegrees: 0, saturation: 0.25, lightness: 0.5), 0.5, accuracy: 1e-9)
    }

    // MARK: maskCubeData

    func testMaskCube() {
        let n = 17
        let f = decode(HSLSelection.maskCubeData(selection: redSel, dimension: n))
        XCTAssertEqual(f.count, n * n * n * 4)
        func at(_ r: Int, _ g: Int, _ b: Int) -> [Float] {
            let i = ((b * n + g) * n + r) * 4
            return Array(f[i..<i + 4])
        }
        let red = at(n - 1, 0, 0)   // 純赤 (h 0, s 1, l 0.5)
        XCTAssertEqual(red[0], 1, accuracy: 1e-6); XCTAssertEqual(red[1], 1, accuracy: 1e-6)
        XCTAssertEqual(red[2], 1, accuracy: 1e-6); XCTAssertEqual(red[3], 1)
        let blue = at(0, 0, n - 1)
        XCTAssertEqual(blue[0], 0, accuracy: 1e-6); XCTAssertEqual(blue[3], 1)
        let gray = at(n / 2, n / 2, n / 2) // 彩度 0 → 範囲外
        XCTAssertEqual(gray[1], 0, accuracy: 1e-6)
    }

    // MARK: corrected

    func testCorrectedDesaturatesRedInRange() {
        let c = HSLCorrection(hueShift: 0, satScale: 0, exposureEV: 0, strength: 1)
        let m = HSLSecondary.corrected(r: 1, g: 0, b: 0, selection: redSel, correction: c)
        XCTAssertEqual(m.r, 0.5, accuracy: 1e-9)
        XCTAssertEqual(m.g, 0.5, accuracy: 1e-9)
        XCTAssertEqual(m.b, 0.5, accuracy: 1e-9)
    }

    func testCorrectedLeavesOutOfRangeUntouched() {
        let c = HSLCorrection(hueShift: 40, satScale: 0, exposureEV: 1, strength: 1)
        let m = HSLSecondary.corrected(r: 0, g: 0, b: 1, selection: redSel, correction: c)
        XCTAssertEqual(m.r, 0); XCTAssertEqual(m.g, 0); XCTAssertEqual(m.b, 1)
    }

    func testCorrectedStrengthHalfBlends() {
        let c = HSLCorrection(hueShift: 0, satScale: 0, exposureEV: 0, strength: 0.5)
        let m = HSLSecondary.corrected(r: 1, g: 0, b: 0, selection: redSel, correction: c)
        XCTAssertEqual(m.r, 0.75, accuracy: 1e-9)
        XCTAssertEqual(m.g, 0.25, accuracy: 1e-9)
        XCTAssertEqual(m.b, 0.25, accuracy: 1e-9)
    }

    func testCorrectedExposureAndHueShift() {
        let all = HSLSelection(hueWidth: 360)
        let ev = HSLSecondary.corrected(r: 0.2, g: 0.2, b: 0.2, selection: all,
                                        correction: HSLCorrection(exposureEV: 1))
        XCTAssertEqual(ev.r, 0.4, accuracy: 1e-9)
        let hs = HSLSecondary.corrected(r: 1, g: 0, b: 0, selection: all, correction: HSLCorrection(hueShift: 120))
        XCTAssertEqual(hs.g, 1, accuracy: 1e-9)
        XCTAssertEqual(hs.r, 0, accuracy: 1e-9)
    }

    func testCorrectionIdentity() {
        XCTAssertTrue(HSLCorrection().isIdentity)
        XCTAssertTrue(HSLCorrection(hueShift: 30, satScale: 0, exposureEV: 1, strength: 0).isIdentity)
        XCTAssertFalse(HSLCorrection(hueShift: 10).isIdentity)
        XCTAssertFalse(HSLCorrection(satScale: 0.5).isIdentity)
        XCTAssertFalse(HSLCorrection(exposureEV: 0.5).isIdentity)
    }

    func testCubeDataMatchesCorrected() {
        let c = HSLCorrection(hueShift: 20, satScale: 0.5, exposureEV: 0.3, strength: 0.8)
        let n = HSLSecondary.cubeDimension
        let f = decode(HSLSecondary.cubeData(selection: redSel, correction: c))
        XCTAssertEqual(f.count, n * n * n * 4)
        let step = 1 / Double(n - 1)
        for (r, g, b) in [(32, 4, 2), (20, 10, 5), (0, 0, 32), (16, 16, 16)] {
            let m = HSLSecondary.corrected(r: Double(r) * step, g: Double(g) * step, b: Double(b) * step, selection: redSel, correction: c)
            let i = ((b * n + g) * n + r) * 4
            XCTAssertEqual(Double(f[i]), m.r, accuracy: 1e-6)
            XCTAssertEqual(Double(f[i + 1]), m.g, accuracy: 1e-6)
            XCTAssertEqual(Double(f[i + 2]), m.b, accuracy: 1e-6)
        }
    }

    func testRestoreFromValues() {
        let vals: [String: Double] = ["hueCenter": 10, "hueWidth": 20, "hueFeather": 30, "satMin": 0.1, "satMax": 0.9,
                                       "satFeather": 0.2, "lumMin": 0.3, "lumMax": 0.7, "lumFeather": 0.05,
                                       "hueShift": 15, "satScale": 1.5, "exposure": -1, "strength": 0.6]
        let sel = HSLSecondary.selection(from: { vals[$0] ?? 0 })
        XCTAssertEqual(sel, HSLSelection(hueCenter: 10, hueWidth: 20, hueFeather: 30, satMin: 0.1, satMax: 0.9,
                                         satFeather: 0.2, lumMin: 0.3, lumMax: 0.7, lumFeather: 0.05))
        let cor = HSLSecondary.correction(from: { vals[$0] ?? 0 })
        XCTAssertEqual(cor, HSLCorrection(hueShift: 15, satScale: 1.5, exposureEV: -1, strength: 0.6))
    }

    // MARK: パイプライン画素

    private let pxRect = CGRect(x: 0, y: 0, width: 16, height: 16)

    private func solid(_ r: Int, _ g: Int, _ b: Int) -> CIImage {
        CIImage(color: CIColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)).cropped(to: pxRect)
    }

    /// 1 種類のエフェクトを画像にかけ、中央の画素(RGBA・0〜255)を返す。
    private func run(_ kind: EffectKind, _ values: [String: Double], on img: CIImage) -> [Int] {
        let fx = ResolvedEffect(kind: kind, values: values, color: "#000000")
        let out = EffectPipeline.applyOne(fx, img, rect: pxRect, bounds: pxRect, scale: 1)
        guard let cg = EffectPipeline.makeImage(out, from: pxRect) else { return [-1, -1, -1, -1] }
        var d = [UInt8](repeating: 0, count: 16 * 16 * 4)
        let c = CGContext(data: &d, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(cg, in: CGRect(x: 0, y: 0, width: 16, height: 16))
        let i = (8 * 16 + 8) * 4
        return [Int(d[i]), Int(d[i + 1]), Int(d[i + 2]), Int(d[i + 3])]
    }

    /// 種類の既定値をそのまま並べた引数(`ResolvedEffect.v` と同じ既定の引き方)。
    private func defaults(_ kind: EffectKind, _ overrides: [String: Double] = [:]) -> [String: Double] {
        var v = Dictionary(uniqueKeysWithValues: kind.params.map { ($0.key, $0.defaultValue) })
        for (k, x) in overrides { v[k] = x }
        return v
    }

    private func resolved(_ kind: EffectKind, _ overrides: [String: Double] = [:]) -> [ResolvedEffect] {
        var c = Clip(); c.id = "k"; c.type = .image; c.src = "/a.png"
        var e = Effect(kind)
        e.params = overrides
        c.effects = [e]
        return EffectPipeline.resolve(c, atClipTime: 0)
    }

    func testHSLSecondaryParamsCount() {
        XCTAssertEqual(EffectKind.hslSecondary.params.count, 13)
        XCTAssertEqual(EffectKind.hslSecondary.label, "HSLセカンダリ")
    }

    func testDefaultHSLSecondaryLeavesPixelsUnchanged() {
        for c in [(220, 30, 30), (30, 30, 220), (128, 128, 128)] {
            let v = run(.hslSecondary, defaults(.hslSecondary), on: solid(c.0, c.1, c.2))
            XCTAssertEqual(v[0], c.0, accuracy: 1)
            XCTAssertEqual(v[1], c.1, accuracy: 1)
            XCTAssertEqual(v[2], c.2, accuracy: 1)
        }
    }

    func testRedSelectionDesaturatesOnlyRed() {
        let vals = defaults(.hslSecondary, ["hueCenter": 0, "hueWidth": 60, "hueFeather": 40, "satScale": 0])
        let red = run(.hslSecondary, vals, on: solid(220, 30, 30))
        XCTAssertEqual(red[0], red[1], accuracy: 4, "赤はグレー化: \(red)")
        XCTAssertEqual(red[1], red[2], accuracy: 4, "赤はグレー化: \(red)")
        let blue = run(.hslSecondary, vals, on: solid(30, 30, 220))
        XCTAssertEqual(blue[0], 30, accuracy: 1)
        XCTAssertEqual(blue[1], 30, accuracy: 1)
        XCTAssertEqual(blue[2], 220, accuracy: 1, "青は不変: \(blue)")
    }

    func testDefaultHSLSecondaryEffectIsDroppedByResolve() {
        XCTAssertTrue(resolved(.hslSecondary).isEmpty)
        XCTAssertEqual(resolved(.hslSecondary, ["satScale": 0]).count, 1)
    }
}
