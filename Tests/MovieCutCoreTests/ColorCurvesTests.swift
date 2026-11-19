import XCTest
import CoreGraphics
import CoreImage
@testable import MovieCutCore

/// RGB↔HSL 変換とカーブ(トーン・色相)・LUT の数値テスト。
final class ColorCurvesTests: XCTestCase {
    /// cubeData を Float 配列へ復号する。
    private func decode(_ data: Data) -> [Float] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    // MARK: ColorHSL

    func testHSLRoundTrip() {
        let colors: [(Double, Double, Double)] = [
            (0.2, 0.5, 0.7), (0.9, 0.1, 0.3), (0.33, 0.33, 0.33), (1, 0.5, 0), (0.05, 0.95, 0.5),
            (0, 0, 0), (1, 1, 1), (0.6, 0.6, 0.1), (0.123, 0.456, 0.789),
        ]
        for c in colors {
            let h = ColorHSL.hsl(r: c.0, g: c.1, b: c.2)
            let o = ColorHSL.rgb(h: h.h, s: h.s, l: h.l)
            XCTAssertEqual(o.r, c.0, accuracy: 1e-9)
            XCTAssertEqual(o.g, c.1, accuracy: 1e-9)
            XCTAssertEqual(o.b, c.2, accuracy: 1e-9)
            XCTAssertTrue(h.h >= 0 && h.h < 1)
        }
    }

    func testHSLPrimaries() {
        let red = ColorHSL.hsl(r: 1, g: 0, b: 0)
        XCTAssertEqual(red.h, 0, accuracy: 1e-12); XCTAssertEqual(red.s, 1, accuracy: 1e-12); XCTAssertEqual(red.l, 0.5, accuracy: 1e-12)
        XCTAssertEqual(ColorHSL.hsl(r: 0, g: 1, b: 0).h, 1.0 / 3, accuracy: 1e-12)
        XCTAssertEqual(ColorHSL.hsl(r: 0, g: 0, b: 1).h, 2.0 / 3, accuracy: 1e-12)
        let white = ColorHSL.hsl(r: 1, g: 1, b: 1)
        XCTAssertEqual(white.s, 0, accuracy: 1e-12); XCTAssertEqual(white.l, 1, accuracy: 1e-12)
        let gray = ColorHSL.hsl(r: 0.4, g: 0.4, b: 0.4)
        XCTAssertEqual(gray.s, 0, accuracy: 1e-12); XCTAssertEqual(gray.h, 0, accuracy: 1e-12)
    }

    func testHSLClampAndNonFinite() {
        let n = ColorHSL.hsl(r: .nan, g: .infinity, b: -3)
        XCTAssertTrue(n.h.isFinite && n.s.isFinite && n.l.isFinite)
        let w = ColorHSL.rgb(h: 1.25, s: 1, l: 0.5) // 1.25 → 0.25(循環)
        let ref = ColorHSL.rgb(h: 0.25, s: 1, l: 0.5)
        XCTAssertEqual(w.r, ref.r, accuracy: 1e-12); XCTAssertEqual(w.g, ref.g, accuracy: 1e-12)
        let neg = ColorHSL.rgb(h: -0.75, s: 2, l: 0.5)
        XCTAssertEqual(neg.r, ref.r, accuracy: 1e-12); XCTAssertEqual(neg.b, ref.b, accuracy: 1e-12)
        let nf = ColorHSL.rgb(h: .nan, s: .nan, l: .nan)
        XCTAssertTrue(nf.r.isFinite && nf.g.isFinite && nf.b.isFinite)
    }

    // MARK: トーンカーブ

    func testIdentityCurveEvalIsExact() {
        var x = 0.0
        while x <= 1.0 {
            XCTAssertEqual(ColorCurves.eval(.identity, x), x, accuracy: 1e-12)
            x += 0.001
        }
        XCTAssertEqual(ColorCurves.eval(.identity, 1), 1, accuracy: 1e-12)
        XCTAssertEqual(ColorCurves.eval(.identity, -1), 0, accuracy: 1e-12)
        XCTAssertEqual(ColorCurves.eval(.identity, 2), 1, accuracy: 1e-12)
    }

    func testCurvePassesThroughControlPoints() {
        let curve = ColorCurves.Curve(y: [0.1, 0.4, 0.45, 0.9, 0.8])
        for (i, x) in ColorCurves.anchorX.enumerated() {
            XCTAssertEqual(ColorCurves.eval(curve, x), curve.y[i], accuracy: 1e-12)
        }
    }

    func testSCurve() {
        let s = ColorCurves.Curve(y: [0, 0.15, 0.5, 0.85, 1])
        XCTAssertEqual(ColorCurves.eval(s, 0.5), 0.5, accuracy: 1e-12)
        XCTAssertEqual(ColorCurves.eval(s, 0.25), 0.15, accuracy: 1e-12)
        // 中点を持ち上げる: eval(0.5) がその y に一致し、0.25 の出力は恒等より大きい
        let lift = ColorCurves.Curve(y: [0, 0.25, 0.75, 0.75, 1])
        XCTAssertEqual(ColorCurves.eval(lift, 0.5), 0.75, accuracy: 1e-12)
        XCTAssertGreaterThan(ColorCurves.eval(lift, 0.25), ColorCurves.eval(.identity, 0.25) - 1e-15)
        let lift2 = ColorCurves.Curve(y: [0, 0.25, 0.75, 0.75, 1])
        XCTAssertGreaterThan(ColorCurves.eval(lift2, 0.4), 0.4)
        XCTAssertGreaterThan(ColorCurves.eval(lift2, 0.3), 0.3)
    }

    func testEndpointsFixed() {
        let c = ColorCurves.Curve(y: [0, 0.8, 0.2, 0.9, 1])
        XCTAssertEqual(ColorCurves.eval(c, 0), 0, accuracy: 1e-12)
        XCTAssertEqual(ColorCurves.eval(c, 1), 1, accuracy: 1e-12)
        // 出力は常に 0...1 にクランプ
        let wild = ColorCurves.Curve(y: [0, 1, 0, 1, 0])
        var x = 0.0
        while x <= 1 {
            let v = ColorCurves.eval(wild, x)
            XCTAssertTrue(v >= 0 && v <= 1)
            x += 0.01
        }
    }

    // MARK: LUT

    func testIdentityCubeDecodesToIdentity() {
        let n = ColorCurves.cubeDimension
        let f = decode(ColorCurves.cubeData(tone: .identity, hue: .identity))
        XCTAssertEqual(f.count, n * n * n * 4)
        let step = 1 / Float(n - 1)
        for b in 0..<n { for g in 0..<n { for r in 0..<n {
            let i = ((b * n + g) * n + r) * 4
            XCTAssertEqual(f[i], Float(r) * step, accuracy: 1e-6)
            XCTAssertEqual(f[i + 1], Float(g) * step, accuracy: 1e-6)
            XCTAssertEqual(f[i + 2], Float(b) * step, accuracy: 1e-6)
            XCTAssertEqual(f[i + 3], 1)
        } } }
    }

    func testNonIdentityCubeMatchesPrediction() {
        var tone = ColorCurves.ToneCurves.identity
        tone.master = ColorCurves.Curve(y: [0, 0.25, 0.75, 0.75, 1])
        let n = ColorCurves.cubeDimension
        let f = decode(ColorCurves.cubeData(tone: tone, hue: .identity))
        let step = 1 / Double(n - 1)
        // 中間グレーの格子点(n = 33 なら 16 が 0.4848、32/2 = 16)
        for k in [8, 16, 24] {
            let v = Double(k) * step
            let m = ColorCurves.mapRGB(r: v, g: v, b: v, tone: tone, hue: .identity)
            let i = ((k * n + k) * n + k) * 4
            XCTAssertEqual(Double(f[i]), m.r, accuracy: 1e-6)
            XCTAssertEqual(Double(f[i + 1]), m.g, accuracy: 1e-6)
            XCTAssertEqual(Double(f[i + 2]), m.b, accuracy: 1e-6)
        }
        // 実際に持ち上がっている
        let mid = ((16 * n + 16) * n + 16) * 4
        XCTAssertGreaterThan(f[mid], Float(16) / 32 + 0.05)
    }

    func testMapRGBIdentityReturnsInputExactly() {
        let m = ColorCurves.mapRGB(r: 0.123456789, g: 0.9, b: 0.31, tone: .identity, hue: .identity)
        XCTAssertEqual(m.r, 0.123456789); XCTAssertEqual(m.g, 0.9); XCTAssertEqual(m.b, 0.31)
    }

    // MARK: 色相カーブ

    func testHueShiftRedToGreen() {
        var hue = ColorCurves.HueCurves.identity
        hue.hueShiftY = Array(repeating: 120, count: 5)
        let m = ColorCurves.mapRGB(r: 1, g: 0, b: 0, tone: .identity, hue: hue)
        XCTAssertEqual(m.r, 0, accuracy: 0.02)
        XCTAssertEqual(m.g, 1, accuracy: 0.02)
        XCTAssertEqual(m.b, 0, accuracy: 0.02)
    }

    func testSaturationZeroGoesGray() {
        var hue = ColorCurves.HueCurves.identity
        hue.satScaleY = Array(repeating: 0, count: 5)
        let m = ColorCurves.mapRGB(r: 1, g: 0.2, b: 0.1, tone: .identity, hue: hue)
        XCTAssertEqual(m.r, m.g, accuracy: 1e-9)
        XCTAssertEqual(m.g, m.b, accuracy: 1e-9)
    }

    func testHueCurveIsCyclicAtSeam() {
        let hue = ColorCurves.HueCurves(hueShiftY: [90, -30, 0, 45, 10],
                                        satScaleY: [1.5, 0.5, 1, 1.2, 0.8],
                                        lumOffsetY: [0.1, -0.1, 0, 0.05, 0])
        // 曲線そのものが継ぎ目でつながる
        XCTAssertEqual(hue.hueShift(at: 0.0001), hue.hueShift(at: 0.9999), accuracy: 0.1)
        XCTAssertEqual(hue.satScale(at: 0.0001), hue.satScale(at: 0.9999), accuracy: 0.01)
        XCTAssertEqual(hue.lumOffset(at: 0.0001), hue.lumOffset(at: 0.9999), accuracy: 0.001)
        XCTAssertEqual(hue.hueShift(at: 0), 90, accuracy: 1e-12)
        XCTAssertEqual(hue.hueShift(at: 1), 90, accuracy: 1e-12)
        // 出力の色も近い
        func rgb(_ h: Double) -> (r: Double, g: Double, b: Double) {
            let c = ColorHSL.rgb(h: h, s: 0.8, l: 0.5)
            return ColorCurves.mapRGB(r: c.r, g: c.g, b: c.b, tone: .identity, hue: hue)
        }
        let a = rgb(0.001), b = rgb(0.999)
        XCTAssertEqual(a.r, b.r, accuracy: 0.05)
        XCTAssertEqual(a.g, b.g, accuracy: 0.05)
        XCTAssertEqual(a.b, b.b, accuracy: 0.05)
    }

    // MARK: 引数からの復元

    func testRestoreFromValues() {
        let tone = ColorCurves.toneCurves(from: { key in
            if key == "red2" { return 0.9 }
            let idx = Int(String(key.last!))!
            return ColorCurves.anchorX[idx]
        })
        XCTAssertEqual(tone.red.y[2], 0.9)
        XCTAssertEqual(tone.master, .identity)
        XCTAssertEqual(tone.green, .identity)
        let hue = ColorCurves.hueCurves(from: { key in
            if key.hasPrefix("hueHue") { return 10 }
            if key.hasPrefix("hueSat") { return 1.5 }
            return -0.1
        })
        XCTAssertEqual(hue.hueShiftY, Array(repeating: 10, count: 5))
        XCTAssertEqual(hue.satScaleY, Array(repeating: 1.5, count: 5))
        XCTAssertEqual(hue.lumOffsetY, Array(repeating: -0.1, count: 5))
        XCTAssertFalse(ColorCurves.isIdentity(tone: tone, hue: .identity))
        XCTAssertTrue(ColorCurves.isIdentity(tone: .identity, hue: .identity))
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

    func testColorCurvesParamsCountAndKeys() {
        let ps = EffectKind.colorCurves.params
        XCTAssertEqual(ps.count, 35)
        XCTAssertEqual(Set(ps.map(\.key)).count, 35)
        XCTAssertEqual(EffectKind.colorCurves.label, "カラーカーブ")
        XCTAssertEqual(ps.first?.label, "マスター点1")
        XCTAssertEqual(EffectKind.colorCurves.spec("red2")?.defaultValue ?? -1, 0.5, accuracy: 1e-12)
        XCTAssertEqual(EffectKind.colorCurves.spec("hueSat3")?.defaultValue, 1)
    }

    func testIdentityColorCurvesLeavePixelsUnchanged() {
        for c in [(0, 0, 0), (128, 128, 128), (200, 40, 90), (255, 255, 255)] {
            let v = run(.colorCurves, defaults(.colorCurves), on: solid(c.0, c.1, c.2))
            XCTAssertEqual(v[0], c.0, accuracy: 1)
            XCTAssertEqual(v[1], c.1, accuracy: 1)
            XCTAssertEqual(v[2], c.2, accuracy: 1)
        }
    }

    func testMasterMidpointLiftBrightensMidGray() {
        let v = run(.colorCurves, defaults(.colorCurves, ["master2": 0.75]), on: solid(128, 128, 128))
        XCTAssertGreaterThan(v[0], 160, "中間グレーが明るくなる: \(v)")
        XCTAssertEqual(v[0], v[1], accuracy: 1)
        XCTAssertEqual(v[1], v[2], accuracy: 1)
    }

    func testDefaultColorCurvesEffectIsDroppedByResolve() {
        XCTAssertTrue(resolved(.colorCurves).isEmpty)
        XCTAssertEqual(resolved(.colorCurves, ["master2": 0.75]).count, 1)
    }
}
