import XCTest
import CoreGraphics
import CoreImage
@testable import MovieCutCore

/// ベベル系(Bevel Alpha / Bevel & Emboss)と放射ブラーの検証(棚卸し残り候補)。
/// 既知入力(アルファ形状・階調の段差・点)で、縁のハイライト/シャドウ、放射方向の流れ、
/// 既定値での恒等性、引数の保存/復元とキーフレーム解決を見る。
final class BevelRadialBlurTests: XCTestCase {
    static let newKinds: [EffectKind] = [.bevelAlpha, .bevelEmboss, .radialBlur]

    // MARK: ヘルパ(EffectsExpansionTests と同じ作法)

    func solid(_ w: Int, _ h: Int, r: UInt8, g: UInt8, b: UInt8) -> CGImage {
        let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1))
        c.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return c.makeImage()!
    }

    /// 透明な地に、不透明なグレーの四角(中央)。
    func shapeImage(_ w: Int, _ h: Int, gray: UInt8 = 128) -> CGImage {
        let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.clear(CGRect(x: 0, y: 0, width: w, height: h))
        c.setFillColor(CGColor(srgbRed: CGFloat(gray) / 255, green: CGFloat(gray) / 255, blue: CGFloat(gray) / 255, alpha: 1))
        c.fill(CGRect(x: w / 4, y: h / 4, width: w / 2, height: h / 2))
        return c.makeImage()!
    }

    /// 左半分が黒・右半分が白(不透明)。
    func halfImage(_ w: Int, _ h: Int) -> CGImage {
        let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
        c.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)); c.fill(CGRect(x: w / 2, y: 0, width: w / 2, height: h))
        return c.makeImage()!
    }

    /// 黒地に白い点(中心の右)。
    func dotImage(_ w: Int, _ h: Int) -> CGImage {
        let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
        c.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)); c.fill(CGRect(x: 88, y: 57, width: 6, height: 6))
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

    /// RGBA(読み出しは乗算済み。A=255 の所では R がそのまま色)。
    func px(_ d: [UInt8], _ w: Int, _ x: Int, _ y: Int) -> [Int] {
        let i = (y * w + x) * 4; return [Int(d[i]), Int(d[i + 1]), Int(d[i + 2]), Int(d[i + 3])]
    }

    func brightCount(_ d: [UInt8], over: Int = 60) -> Int {
        var n = 0; for i in stride(from: 0, to: d.count, by: 4) { if d[i] > over { n += 1 } }; return n
    }

    // MARK: 仕様・登録

    func testNewKindsAreRegisteredWithLabelsAndParams() {
        XCTAssertEqual(EffectKind.allCases.count, 48, "統合前 45 種 + 新規 3 種")
        XCTAssertEqual(EffectKind.bevelAlpha.label, "ベベル（アルファ）")
        XCTAssertEqual(EffectKind.bevelEmboss.label, "ベベル＆エンボス")
        XCTAssertEqual(EffectKind.radialBlur.label, "放射ブラー")
        XCTAssertEqual(EffectKind.bevelAlpha.params.map(\.key), ["size", "angle", "softness", "highlight", "shadow"])
        XCTAssertEqual(EffectKind.bevelEmboss.params.map(\.key), ["depth", "angle", "softness", "strength"])
        XCTAssertEqual(EffectKind.radialBlur.params.map(\.key), ["amount", "centerX", "centerY", "mode"])
        XCTAssertEqual(EffectKind.radialBlur.spec("mode")?.unit, .radialMode)
        for k in Self.newKinds {
            XCTAssertEqual(Effect(k).known, k)
            for s in k.params { XCTAssertTrue(s.range.contains(s.defaultValue), "\(k) \(s.key)") }
        }
    }

    func testParamClamping() {
        var e = Effect(.bevelAlpha); e.params["size"] = 999
        XCTAssertEqual(e.value("size"), 40)
        var r = Effect(.radialBlur); r.params["centerX"] = -1
        XCTAssertEqual(r.value("centerX"), 0)
        r.params["amount"] = .nan
        XCTAssertEqual(r.value("amount"), 0, "NaN は既定値(恒等)")
    }

    func testModeMapping() {
        XCTAssertEqual(RadialBlur.mode(value: 0), .zoom)
        XCTAssertEqual(RadialBlur.mode(value: 0.6), .spin)
        XCTAssertEqual(RadialBlur.mode(value: 99), .spin, "範囲外は収める")
        XCTAssertEqual(RadialBlur.mode(value: .nan), .zoom)
        XCTAssertEqual(RadialBlur.spinDegrees(forAmount: 100), 90, accuracy: 1e-9)
    }

    func testLightVector() {
        XCTAssertEqual(Bevel.lightVector(angleDegrees: 0).x, 1, accuracy: 1e-9)
        XCTAssertEqual(Bevel.lightVector(angleDegrees: 0).y, 0, accuracy: 1e-9)
        XCTAssertEqual(Bevel.lightVector(angleDegrees: 90).y, 1, accuracy: 1e-9)
        XCTAssertEqual(Bevel.lightVector(angleDegrees: 135).x, -0.7071, accuracy: 1e-3)
        XCTAssertEqual(Bevel.lightVector(angleDegrees: 135).y, 0.7071, accuracy: 1e-3)
    }

    // MARK: 恒等性(既定値・無効値では従来と画素一致)

    func testDefaultsAreIdentity() {
        for k in Self.newKinds {
            var c = Clip(); c.effects = [Effect(k)]
            XCTAssertTrue(EffectPipeline.resolve(c, atClipTime: 0).isEmpty, "\(k) の既定値は「何もしない」")
        }
        // 解決を経ずに直接かけても、既定値では画素が一致する
        let src = shapeImage(80, 80)
        let base = rgba(src)
        XCTAssertEqual(apply(src, .bevelAlpha, ["size": 0, "angle": 135, "softness": 4, "highlight": 0.7, "shadow": 0.7]), base)
        XCTAssertEqual(apply(src, .bevelEmboss, ["depth": 0, "angle": 135, "softness": 2, "strength": 0.8]), base)
        let half = halfImage(80, 80)
        XCTAssertEqual(apply(half, .radialBlur, ["amount": 0, "centerX": 0.5, "centerY": 0.5, "mode": 0]), rgba(half))
    }

    func testIdentityValuesAreDroppedByResolve() {
        let cases: [(EffectKind, [String: Double])] = [
            (.bevelAlpha, ["size": 0]), (.bevelAlpha, ["size": 10, "highlight": 0, "shadow": 0]),
            (.bevelEmboss, ["depth": 0]), (.bevelEmboss, ["depth": 10, "strength": 0]),
            (.radialBlur, ["amount": 0]),
        ]
        for (k, v) in cases {
            var e = Effect(k); for (key, val) in v { e.params[key] = val }
            var c = Clip(); c.effects = [e]
            XCTAssertTrue(EffectPipeline.resolve(c, atClipTime: 0).isEmpty, "\(k) \(v) は何もしない値で外れる")
        }
        // 無効化したものも外れる
        var e = Effect(.bevelAlpha); e.params["size"] = 12; e.enabled = false
        var c = Clip(); c.effects = [e]
        XCTAssertTrue(EffectPipeline.resolve(c, atClipTime: 0).isEmpty)
    }

    // MARK: Bevel Alpha

    func testBevelAlphaHighlightAndShadowOnAlphaEdge() {
        // 四角は 30〜90(120×120)。光は右から(角度 0): 右の内縁がハイライト、左の内縁がシャドウ。
        let src = shapeImage(120, 120)
        let out = apply(src, .bevelAlpha, ["size": 10, "angle": 0, "softness": 4, "highlight": 1, "shadow": 1])
        XCTAssertGreaterThan(px(out, 120, 85, 60)[0], 128 + 25, "光に面した右の内縁が明るくなる: \(px(out, 120, 85, 60))")
        XCTAssertLessThan(px(out, 120, 35, 60)[0], 128 - 25, "反対側の左の内縁が暗くなる: \(px(out, 120, 35, 60))")
        XCTAssertEqual(px(out, 120, 60, 60)[0], 128, accuracy: 3, "平らな内側は変わらない")
        XCTAssertEqual(px(out, 120, 60, 60)[3], 255)
        XCTAssertEqual(px(out, 120, 10, 60)[3], 0, "形の外は透明のまま(シルエットは広がらない)")
        // 光を逆(180°)にすると明暗が入れ替わる
        let rev = apply(src, .bevelAlpha, ["size": 10, "angle": 180, "softness": 4, "highlight": 1, "shadow": 1])
        XCTAssertLessThan(px(rev, 120, 85, 60)[0], 128 - 25)
        XCTAssertGreaterThan(px(rev, 120, 35, 60)[0], 128 + 25)
    }

    func testBevelAlphaOnFlatOpaqueImageIsPixelIdentical() {
        // アルファの輪郭が無い(全面不透明で平ら)絵では、場が一定でマスクが 0 → 画素一致
        let src = solid(100, 100, r: 90, g: 140, b: 200)
        let out = apply(src, .bevelAlpha, ["size": 12, "angle": 135, "softness": 6, "highlight": 1, "shadow": 1])
        XCTAssertEqual(out, rgba(src))
    }

    func testBevelAlphaKeepsTransparencyAlone() {
        let c = CGContext(data: nil, width: 60, height: 60, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.clear(CGRect(x: 0, y: 0, width: 60, height: 60))
        let src = c.makeImage()!
        let out = apply(src, .bevelAlpha, ["size": 10, "angle": 135, "softness": 4, "highlight": 1, "shadow": 1])
        XCTAssertEqual(out, rgba(src), "全面透明では何も生まれない")
    }

    // MARK: Bevel & Emboss

    func testBevelEmbossOnStepEdge() {
        // 左が黒・右が白の段差。光が右(角度 0)なら段差の白側がシャドウで沈み、
        // 光が左(角度 180)なら段差の黒側がハイライトで浮く。
        let src = halfImage(120, 120)
        let shadowed = apply(src, .bevelEmboss, ["depth": 10, "angle": 0, "softness": 3, "strength": 1])
        XCTAssertLessThan(px(shadowed, 120, 66, 60)[0], 255 - 40, "白側の縁が暗くなる: \(px(shadowed, 120, 66, 60))")
        XCTAssertEqual(px(shadowed, 120, 100, 60)[0], 255, accuracy: 2, "縁から離れた白は変わらない")
        let lit = apply(src, .bevelEmboss, ["depth": 10, "angle": 180, "softness": 3, "strength": 1])
        XCTAssertGreaterThan(px(lit, 120, 54, 60)[0], 40, "黒側の縁が明るくなる: \(px(lit, 120, 54, 60))")
        XCTAssertEqual(px(lit, 120, 20, 60)[0], 0, accuracy: 2, "縁から離れた黒は変わらない")
    }

    func testBevelEmbossOnFlatImageIsPixelIdentical() {
        let src = solid(100, 100, r: 77, g: 77, b: 77)
        let out = apply(src, .bevelEmboss, ["depth": 12, "angle": 135, "softness": 4, "strength": 1])
        XCTAssertEqual(out, rgba(src), "平らな絵では輝度の傾きが無く、画素一致")
    }

    func testBevelEmbossAlsoRespondsToAlphaShape() {
        // 透明な地の四角でも、輝度場(透明=0)との段差で縁が浮く(Bevel Alpha との違いは docs に明記)
        let src = shapeImage(120, 120)
        let out = apply(src, .bevelEmboss, ["depth": 10, "angle": 0, "softness": 4, "strength": 1])
        XCTAssertNotEqual(out, rgba(src))
        XCTAssertEqual(px(out, 120, 10, 60)[3], 0, "形の外は透明のまま")
    }

    // MARK: 放射ブラー

    func testRadialZoomSmearsAlongRadialDirection() {
        let src = dotImage(120, 120)
        let base = rgba(src)
        let out = apply(src, .radialBlur, ["amount": 60, "centerX": 0.5, "centerY": 0.5, "mode": 0])
        XCTAssertGreaterThan(brightCount(out), brightCount(base) * 2, "点が放射状に広がる")
        // 放射方向(点から右=中心から外向き)には光が伸びる
        var radial = 0
        for y in 55...65 { for x in 96...118 { if px(out, 120, x, y)[0] > 60 { radial += 1 } } }
        XCTAssertGreaterThanOrEqual(radial, 8, "外向きの腕に光が伸びる: \(radial)")
        // 接線方向(点の上)には伸びない
        var tangent = 0
        for y in 74...96 { for x in 86...96 { if px(out, 120, x, y)[0] > 60 { tangent += 1 } } }
        XCTAssertLessThan(tangent, radial, "接線方向へは伸びない: 接線 \(tangent) / 放射 \(radial)")
        // 中心そのものはほぼ変わらない
        XCTAssertEqual(px(out, 120, 60, 60)[0], 0, accuracy: 2)
    }

    func testRadialSpinModeSmearsAlongArc() {
        let src = dotImage(120, 120)
        let out = apply(src, .radialBlur, ["amount": 40, "centerX": 0.5, "centerY": 0.5, "mode": 1])
        XCTAssertGreaterThan(brightCount(out), brightCount(rgba(src)) * 2, "回転方式では点が円弧状に広がる")
    }

    func testRadialCenterOnDotReducesSmear() {
        // 点(88〜94, 中心 91)の真上に中心を置くと、放射方向の距離がほぼ 0 で流れが消える
        let src = dotImage(120, 120)
        let onDot = apply(src, .radialBlur, ["amount": 60, "centerX": 91.0 / 120, "centerY": 0.5, "mode": 0])
        let offCenter = apply(src, .radialBlur, ["amount": 60, "centerX": 0.5, "centerY": 0.5, "mode": 0])
        XCTAssertLessThan(brightCount(onDot), Int(Double(brightCount(offCenter)) * 0.7),
                          "中心上の点は流れない: 中心上 \(brightCount(onDot)) / 既定中心 \(brightCount(offCenter))")
    }

    func testRadialBlurFlatImageIsUnchangedWithinRounding() {
        // 一様な絵は拡縮しても一様(多重サンプルの足し合わせの丸めで ±2 まで)
        let src = solid(80, 80, r: 160, g: 160, b: 160)
        let out = apply(src, .radialBlur, ["amount": 80, "centerX": 0.5, "centerY": 0.5, "mode": 0])
        let base = rgba(src)
        XCTAssertEqual(out.count, base.count)
        for i in 0..<out.count { XCTAssertLessThanOrEqual(abs(Int(out[i]) - Int(base[i])), 2, "画素 \(i)") }
    }

    // MARK: キーフレーム・保存/復元

    func testKeyframeResolutionDrivesParams() {
        var c = Clip()
        var e = Effect(.radialBlur)   // amount の既定は 0(恒等)
        c.effects = [e]
        XCTAssertTrue(EffectPipeline.resolve(c, atClipTime: 1).isEmpty, "キー無し・既定値では外れる")
        c.keyframes["fx.0.amount"] = [Keyframe(t: 0, v: 0), Keyframe(t: 2, v: 100)]
        let mid = EffectPipeline.resolve(c, atClipTime: 1)
        XCTAssertEqual(mid.count, 1)
        XCTAssertEqual(mid[0].v("amount"), 50, accuracy: 1e-9, "キーフレームの中間値で解決される")
        _ = e
    }

    func testSaveRestoreRoundTrip() throws {
        var clip = Clip(); clip.type = .image; clip.src = "/a.png"
        var a = Effect(.bevelAlpha); a.params = ["size": 9, "angle": 45, "softness": 3, "highlight": 0.5, "shadow": 0.25]
        var b = Effect(.bevelEmboss); b.params = ["depth": 7, "angle": -30, "softness": 1, "strength": 0.4]
        var r = Effect(.radialBlur); r.params = ["amount": 33, "centerX": 0.25, "centerY": 0.75, "mode": 1]
        clip.effects = [a, b, r]
        clip.keyframes["fx.2.amount"] = [Keyframe(t: 0, v: 0), Keyframe(t: 1, v: 66)]
        var p = Project(); p.tracks = [Track(name: "t")]; p.tracks[0].clips = [clip]
        let data = try p.encoded()
        let p2 = try Project.decode(from: data)
        XCTAssertEqual(p, p2)
        let restored = p2.allClips[0]
        XCTAssertEqual(restored.effects.map(\.kind), ["bevelAlpha", "bevelEmboss", "radialBlur"])
        XCTAssertEqual(restored.effects[0].params["size"], 9)
        XCTAssertEqual(restored.effects[1].params["angle"], -30)
        XCTAssertEqual(restored.effects[2].params["mode"], 1)
        XCTAssertEqual(restored.keyframes["fx.2.amount"]?.count, 2)
        // 復元したものも解決できる(キーの中間値)
        let resolved = EffectPipeline.resolve(restored, atClipTime: 0.5)
        XCTAssertEqual(resolved.map(\.kind), [.bevelAlpha, .bevelEmboss, .radialBlur])
        XCTAssertEqual(resolved[2].v("amount"), 33, accuracy: 1e-9)
    }
}
