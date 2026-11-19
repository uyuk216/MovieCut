import XCTest
import CoreGraphics
import CoreImage
@testable import MovieCutCore

/// 第2波B2で追加した汎用加工エフェクト(監査#57): 既知入力→期待される変化を画素で見る。
final class EffectsExpansionTests: XCTestCase {
    static let newKinds: [EffectKind] = [.invert, .posterize, .unsharpMask, .edges, .crystallize, .hexPixelate,
                                         .pointillize, .twirl, .lensDistortion, .halftone, .kaleidoscope, .tritone,
                                         .solarize, .spinBlur, .edgeBlur, .echo]

    // MARK: ヘルパ

    func textured(_ w: Int, _ h: Int, seed: UInt64 = 999) -> CGImage {
        var d = [UInt8](repeating: 255, count: w * h * 4)
        var s = seed
        func next() -> UInt8 { s = s &* 6364136223846793005 &+ 1442695040888963407; return UInt8(truncatingIfNeeded: s >> 33) }
        for i in 0..<(w * h) { d[i * 4] = next(); d[i * 4 + 1] = next(); d[i * 4 + 2] = next() }
        return d.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        }
    }

    func solid(_ w: Int, _ h: Int, r: UInt8, g: UInt8, b: UInt8) -> CGImage {
        let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1))
        c.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return c.makeImage()!
    }

    /// 左半分が黒・右半分が白(CGImage の座標。読み出しも同じ向き)。
    func halfImage(_ w: Int, _ h: Int) -> CGImage {
        let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
        c.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)); c.fill(CGRect(x: w / 2, y: 0, width: w / 2, height: h))
        return c.makeImage()!
    }

    func rgba(_ img: CGImage) -> [UInt8] {
        var d = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let c = CGContext(data: &d, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return d
    }

    func apply(_ src: CGImage, _ kind: EffectKind, _ values: [String: Double]) -> [UInt8] {
        let fx = [ResolvedEffect(kind: kind, values: values, color: "#000000")]
        let bounds = CGRect(x: 0, y: 0, width: src.width, height: src.height)
        let out = EffectPipeline.apply(CIImage(cgImage: src), effects: fx, bounds: bounds, scale: 1)
        return rgba(EffectPipeline.makeImage(out, from: bounds)!)
    }

    func px(_ d: [UInt8], _ w: Int, _ x: Int, _ y: Int) -> [Int] {
        let i = (y * w + x) * 4; return [Int(d[i]), Int(d[i + 1]), Int(d[i + 2])]
    }

    func variance(_ d: [UInt8]) -> Double {
        var s = 0.0, s2 = 0.0, n = 0.0
        for i in stride(from: 0, to: d.count, by: 4) { let l = Double(d[i]); s += l; s2 += l * l; n += 1 }
        let m = s / n; return s2 / n - m * m
    }

    // MARK: 仕様・解決

    func testNewKindsHaveLabelsParamsAndNonIdentityDefaults() {
        for k in Self.newKinds {
            XCTAssertFalse(k.label.isEmpty, "\(k)")
            XCTAssertFalse(k.params.isEmpty, "\(k)")
            var c = Clip(); c.effects = [Effect(k)]
            XCTAssertEqual(EffectPipeline.resolve(c, atClipTime: 0).count, 1, "\(k) の既定値は「何もしない」ではない")
            // ファイル往復で種類が保たれる
            let e = Effect(k)
            XCTAssertEqual(e.known, k)
        }
        XCTAssertEqual(EffectKind.allCases.count, 27 + Self.newKinds.count + 2, "既存 27 種(色調転写・映像ノイズ除去を含む) + 新規 16 種 + カラーカーブ・HSLセカンダリ 2 種")
    }

    func testIdentityValuesAreDroppedByResolve() {
        let cases: [(EffectKind, [String: Double])] = [
            (.invert, ["amount": 0]), (.unsharpMask, ["intensity": 0]), (.twirl, ["angle": 0]),
            (.lensDistortion, ["scale": 0]), (.tritone, ["amount": 0]), (.solarize, ["amount": 0]),
            (.spinBlur, ["amount": 0]), (.edgeBlur, ["radius": 0]), (.echo, ["distance": 0]),
        ]
        for (k, v) in cases {
            var e = Effect(k); for (key, val) in v { e.params[key] = val }
            var c = Clip(); c.effects = [e]
            XCTAssertTrue(EffectPipeline.resolve(c, atClipTime: 0).isEmpty, "\(k) は何もしない値で外れる")
        }
    }

    // MARK: 色調系

    func testInvertFlipsChannelsAndHalfAmountGreys() {
        let src = solid(20, 20, r: 200, g: 100, b: 50)
        let out = apply(src, .invert, ["amount": 1])
        let c = px(out, 20, 10, 10)
        XCTAssertEqual(c[0], 55, accuracy: 3); XCTAssertEqual(c[1], 155, accuracy: 3); XCTAssertEqual(c[2], 205, accuracy: 3)
        let half = apply(src, .invert, ["amount": 0.5])
        let h = px(half, 20, 10, 10)
        for ch in h { XCTAssertEqual(ch, 128, accuracy: 3, "半分反転は全チャンネル 0.5") }
    }

    func testPosterizeReducesDistinctValues() {
        // 横グラデーション(R が 0→255)
        let c0 = CGContext(data: nil, width: 64, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                           space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for x in 0..<64 { c0.setFillColor(CGColor(srgbRed: CGFloat(x) / 63, green: 0.4, blue: 0.4, alpha: 1)); c0.fill(CGRect(x: x, y: 0, width: 1, height: 8)) }
        let src = c0.makeImage()!
        let out = apply(src, .posterize, ["levels": 4])
        var distinct = Set<UInt8>()
        for i in stride(from: 0, to: out.count, by: 4) { distinct.insert(out[i]) }
        XCTAssertLessThanOrEqual(distinct.count, 6, "4 階調なら R の distinct は少しだけ: \(distinct.count)")
        XCTAssertNotEqual(out, rgba(src))
    }

    func testTritoneMapsDarkMidBrightToPalette() {
        let dark = px(apply(solid(16, 16, r: 8, g: 8, b: 8), .tritone, ["amount": 1, "palette": 0]), 16, 8, 8)
        XCTAssertEqual(dark[0], Int(0.10 * 255), accuracy: 30); XCTAssertEqual(dark[2], Int(0.25 * 255), accuracy: 30)
        let mid = px(apply(solid(16, 16, r: 128, g: 128, b: 128), .tritone, ["amount": 1, "palette": 0]), 16, 8, 8)
        XCTAssertEqual(mid[0], Int(0.72 * 255), accuracy: 30); XCTAssertEqual(mid[1], Int(0.62 * 255), accuracy: 30)
        let hi = px(apply(solid(16, 16, r: 248, g: 248, b: 248), .tritone, ["amount": 1, "palette": 0]), 16, 8, 8)
        XCTAssertEqual(hi[0], 255, accuracy: 20); XCTAssertEqual(hi[2], Int(0.85 * 255), accuracy: 30)
        // パレットを変えると色が変わる
        let blue = px(apply(solid(16, 16, r: 128, g: 128, b: 128), .tritone, ["amount": 1, "palette": 1]), 16, 8, 8)
        XCTAssertGreaterThan(blue[2], blue[0] + 40, "ブルーのパレットは青い")
    }

    func testSolarizeInvertsAboveThresholdOnly() {
        let bright = px(apply(solid(16, 16, r: 200, g: 200, b: 200), .solarize, ["amount": 1, "threshold": 0.5]), 16, 8, 8)
        XCTAssertEqual(bright[0], 55, accuracy: 12)
        let dark = px(apply(solid(16, 16, r: 50, g: 50, b: 50), .solarize, ["amount": 1, "threshold": 0.5]), 16, 8, 8)
        XCTAssertEqual(dark[0], 50, accuracy: 12)
    }

    // MARK: シャープ・輪郭

    func testUnsharpMaskRaisesVarianceOfBlurredNoise() {
        let src = textured(100, 100)
        let blurred = apply(src, .gaussianBlur, ["radius": 3])
        // ぼかした画素列を画像に戻してアンシャープをかける代わりに、直接 CI で連鎖させる
        let fx = [ResolvedEffect(kind: .gaussianBlur, values: ["radius": 3], color: "#000000"),
                  ResolvedEffect(kind: .unsharpMask, values: ["radius": 4, "intensity": 2], color: "#000000")]
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let out = rgba(EffectPipeline.makeImage(EffectPipeline.apply(CIImage(cgImage: src), effects: fx, bounds: bounds, scale: 1), from: bounds)!)
        XCTAssertGreaterThan(variance(out), variance(blurred) * 1.3, "アンシャープで分散が戻る方向に増える")
    }

    func testEdgesTracesOnlyTheBoundary() {
        // 黒地に白い四角 → 輪郭抽出では四角の縁だけが光り、内側も外側も黒い
        let c = CGContext(data: nil, width: 120, height: 120, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 120, height: 120))
        c.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)); c.fill(CGRect(x: 84, y: 54, width: 12, height: 12))
        let src = c.makeImage()!
        let out = apply(src, .edges, ["intensity": 3])
        var lit = 0
        for i in stride(from: 0, to: out.count, by: 4) { if out[i] > 100 { lit += 1 } }
        XCTAssertGreaterThan(lit, 15, "縁の画素が光る: \(lit)")
        XCTAssertLessThan(lit, 300, "全面ではない(縁だけ)")
        XCTAssertEqual(px(out, 120, 90, 60)[0], 0, "四角の内側は黒")
        XCTAssertEqual(px(out, 120, 20, 60)[0], 0, "四角の外側は黒")
        // ノイズ絵でも入力と変わる
        XCTAssertNotEqual(apply(textured(80, 80), .edges, ["intensity": 3]), rgba(textured(80, 80)))
    }

    // MARK: モザイク形状

    func testMosaicShapesReduceVarianceOfNoise() {
        let src = textured(100, 100)
        let base = variance(rgba(src))
        let shapes: [(EffectKind, [String: Double])] = [(.crystallize, ["size": 14]), (.hexPixelate, ["size": 14]), (.pointillize, ["size": 10])]
        for (k, v) in shapes {
            let out = apply(src, k, v)
            XCTAssertNotEqual(out, rgba(src), "\(k)")
            XCTAssertLessThan(variance(out), base * 0.85, "\(k) はノイズの分散を下げる")
        }
    }

    func testCrystallizeAndHexMakeFlatBlocks() {
        // 隣り合う画素が同じ色になる割合が上がる(ブロック化)
        let src = textured(100, 100)
        func equalPairs(_ d: [UInt8], _ w: Int) -> Double {
            var eq = 0, n = 0
            for y in 10..<90 { for x in 10..<89 { n += 1; if px(d, w, x, y) == px(d, w, x + 1, y) { eq += 1 } } }
            return Double(eq) / Double(n)
        }
        XCTAssertGreaterThan(equalPairs(apply(src, .crystallize, ["size": 16]), 100), equalPairs(rgba(src), 100) + 0.15)
        XCTAssertGreaterThan(equalPairs(apply(src, .hexPixelate, ["size": 16]), 100), equalPairs(rgba(src), 100) + 0.15)
    }

    // MARK: 歪み・万華鏡・網点

    func testTwirlChangesInsideRadiusOnly() {
        let src = halfImage(120, 120)
        let base = rgba(src)
        let out = apply(src, .twirl, ["radius": 40, "angle": 180])
        XCTAssertEqual(px(out, 120, 75, 60), [0, 0, 0], "半径の中(中心の右 15px)は回って黒い側を拾う")
        XCTAssertEqual(px(out, 120, 2, 2), px(base, 120, 2, 2), "半径の外は変わらない")
    }

    func testLensDistortionMovesPixelsNearCenter() {
        // 中心を通らない位置の白い四角が、放射方向に引き寄せられて潰れる
        let c = CGContext(data: nil, width: 120, height: 120, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 120, height: 120))
        c.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)); c.fill(CGRect(x: 84, y: 54, width: 12, height: 12))
        let src = c.makeImage()!
        let base = rgba(src)
        let out = apply(src, .lensDistortion, ["scale": 0.8, "radius": 300])
        XCTAssertNotEqual(out, base)
        func whites(_ d: [UInt8]) -> Int { var n = 0; for i in stride(from: 0, to: d.count, by: 4) { if d[i] > 200 { n += 1 } }; return n }
        XCTAssertEqual(whites(base), 144)
        XCTAssertLessThan(whites(out), 72, "四角が中心方向へ潰れる: \(whites(out))")
    }

    func testHalftoneTurnsFlatGreyIntoDots() {
        let src = solid(80, 80, r: 128, g: 128, b: 128)
        let out = apply(src, .halftone, ["width": 7, "angle": 0, "sharpness": 0.8])
        XCTAssertGreaterThan(variance(out), 500, "一様なグレーが網点の模様になる")
    }

    func testKaleidoscopeReplicatesOffCenterMark() {
        // 黒地に中心の右の白い四角(万華鏡の基準の扇の中)→ 他の扇にも白が現れる
        let c = CGContext(data: nil, width: 120, height: 120, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 120, height: 120))
        c.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)); c.fill(CGRect(x: 84, y: 54, width: 12, height: 12))
        let src = c.makeImage()!
        let out = apply(src, .kaleidoscope, ["count": 6, "angle": 0])
        var bright = 0
        for i in stride(from: 0, to: out.count, by: 4) { if out[i] > 200 { bright += 1 } }
        XCTAssertGreaterThan(bright, 12 * 12 * 2, "白い四角が複数の扇に複製される: \(bright)")
    }

    // MARK: ぼかし系の追加・残像

    func testSpinBlurSmearsOffCenterDotAlongArc() {
        let c = CGContext(data: nil, width: 120, height: 120, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 120, height: 120))
        c.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)); c.fill(CGRect(x: 88, y: 57, width: 6, height: 6))
        let src = c.makeImage()!
        let base = rgba(src)
        let out = apply(src, .spinBlur, ["amount": 40])
        func brightCount(_ d: [UInt8]) -> Int { var n = 0; for i in stride(from: 0, to: d.count, by: 4) { if d[i] > 60 { n += 1 } }; return n }
        XCTAssertGreaterThan(brightCount(out), brightCount(base) * 2, "点が円弧状に広がる")
        // 一様な絵は回転ブラーでも明るさが保たれる(コピーの平均になっている)
        let flat = px(apply(solid(60, 60, r: 160, g: 160, b: 160), .spinBlur, ["amount": 40]), 60, 30, 30)
        XCTAssertEqual(flat[0], 160, accuracy: 6, "一様な色は変わらない")
        XCTAssertEqual(px(out, 120, 60, 60), px(base, 120, 60, 60), "中心は変わらない")
    }

    func testEdgeBlurKeepsCenterSharpAndBlursCorners() {
        let src = textured(160, 160)
        let base = rgba(src)
        let out = apply(src, .edgeBlur, ["radius": 10, "inner": 0.45])
        // 中心 30x30 はほぼそのまま
        var centerDiff = 0
        for y in 65..<95 { for x in 65..<95 { if px(out, 160, x, y) != px(base, 160, x, y) { centerDiff += 1 } } }
        XCTAssertLessThan(centerDiff, 30, "中心はシャープなまま: \(centerDiff)")
        // 角の分散は大きく下がる
        func cornerVar(_ d: [UInt8]) -> Double {
            var vals: [Double] = []
            for y in 0..<35 { for x in 0..<35 { vals.append(Double(d[(y * 160 + x) * 4])) } }
            let m = vals.reduce(0, +) / Double(vals.count)
            return vals.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(vals.count)
        }
        XCTAssertLessThan(cornerVar(out), cornerVar(base) * 0.5, "周辺はぼける")
    }

    func testEchoGhostsTheEdge() {
        let src = halfImage(120, 120)
        // 向き 0° = +x 方向へずらす。白い側の内側(x=75)では、黒い側のゴーストが重なり暗くなる。
        let out = apply(src, .echo, ["distance": 20, "angle": 0, "count": 2, "opacity": 0.5])
        let ghosted = px(out, 120, 75, 60)
        XCTAssertLessThan(ghosted[0], 210, "境界の内側に残像が重なる: \(ghosted)")
        XCTAssertGreaterThan(ghosted[0], 60)
        XCTAssertEqual(px(out, 120, 110, 60)[0], 255, accuracy: 2, "境界から遠い白は白いまま")
        XCTAssertEqual(px(out, 120, 10, 60)[0], 0, accuracy: 2, "境界から遠い黒は黒いまま")
    }
}
