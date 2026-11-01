import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import MovieCutCore

/// エフェクト(Core Image): データ・編集・キーフレーム・描画(画素単位)。
final class EffectTests: XCTestCase {
    struct Pixels {
        let w: Int, h: Int
        var d: [UInt8]
        func rgb(_ x: Int, _ y: Int) -> [Int] { let i = (y * w + x) * 4; return [Int(d[i]), Int(d[i + 1]), Int(d[i + 2])] }
        func luma(_ x: Int, _ y: Int) -> Double { let c = rgb(x, y); return 0.2126 * Double(c[0]) + 0.7152 * Double(c[1]) + 0.0722 * Double(c[2]) }
        /// 範囲の輝度の平均・分散
        func stats(_ r: CGRect) -> (mean: Double, variance: Double) {
            var s = 0.0, s2 = 0.0, n = 0.0
            for y in Int(r.minY)..<Int(r.maxY) { for x in Int(r.minX)..<Int(r.maxX) { let l = luma(x, y); s += l; s2 += l * l; n += 1 } }
            let m = s / n
            return (m, s2 / n - m * m)
        }
    }

    func pixels(_ img: CGImage) -> Pixels {
        var d = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let c = CGContext(data: &d, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return Pixels(w: img.width, h: img.height, d: d)
    }

    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("effect-tests-\(UUID().uuidString)")
    override func setUpWithError() throws { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func writePNG(_ img: CGImage, _ name: String) throws -> String {
        let url = tmp.appendingPathComponent(name)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, img, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url.path
    }

    /// 色のついたなだらかな画像(ふつうの写真のようなもの)
    func gradientPNG(size: Int = 100) throws -> String {
        let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for y in 0..<size { for x in 0..<size {
            c.setFillColor(CGColor(srgbRed: CGFloat(x) / CGFloat(size) * 0.8 + 0.1, green: CGFloat(y) / CGFloat(size) * 0.6 + 0.1, blue: 0.7 - CGFloat(x) / CGFloat(size) * 0.5, alpha: 1))
            c.fill(CGRect(x: x, y: y, width: 1, height: 1))
        } }
        return try writePNG(c.makeImage()!, "gradient.png")
    }

    func noisePNG(size: Int = 100) throws -> String {
        var d = [UInt8](repeating: 255, count: size * size * 4)
        var seed: UInt64 = 12345
        func next() -> UInt8 { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return UInt8(truncatingIfNeeded: seed >> 33) }
        for i in 0..<(size * size) { d[i * 4] = next(); d[i * 4 + 1] = next(); d[i * 4 + 2] = next() }
        let img = d.withUnsafeMutableBytes { raw -> CGImage in
            CGContext(data: raw.baseAddress, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        }
        return try writePNG(img, "noise.png")
    }

    func solidPNG(r: UInt8, g: UInt8, b: UInt8, size: Int = 40) throws -> String {
        let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1))
        c.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return try writePNG(c.makeImage()!, "solid\(r)-\(g)-\(b).png")
    }

    /// 200×200 のキャンバスの中央に 100×100 で置いた画像(まわりに 50px の余白)
    func project(_ path: String, effects: [Effect], bg: String = "#808080") -> Project {
        var c = Clip(); c.id = "i"; c.type = .image; c.src = path; c.start = 0; c.duration = 4; c.x = 0.5; c.y = 0.5; c.scale = 0.5
        c.effects = effects
        var p = Project(); p.width = 200; p.height = 200; p.bg = bg; p.characters = []
        var tr = Track(name: "L1"); tr.clips = [c]; p.tracks = [tr]
        return p
    }

    func render(_ p: Project, t: Double = 0.5) throws -> Pixels {
        pixels(try XCTUnwrap(Renderer(project: p, assets: RenderAssets()).renderImage(t: t)))
    }

    let inner = CGRect(x: 55, y: 55, width: 90, height: 90)
    /// px の引数は 1920×1080 での大きさ。この 200×200 のキャンバスで `v` 画素にするための値。
    func px(_ v: Double) -> Double { v / (200.0 * 200.0 / (1920.0 * 1080.0)).squareRoot() }

    func fx(_ k: EffectKind, _ v: [String: Double] = [:], color: String? = nil) -> Effect {
        var e = Effect(k)
        for (key, val) in v { e.params[key] = val }
        if let color { e.color = color }
        return e
    }

    // MARK: 描画(画素)

    func testNoEffectsOrAllDisabledIsPixelIdenticalToTheOldPath() throws {
        let path = try gradientPNG()
        let base = try render(project(path, effects: []))
        var off = fx(.gaussianBlur); off.enabled = false
        XCTAssertEqual(try render(project(path, effects: [off])).d, base.d)
        XCTAssertEqual(try render(project(path, effects: [Effect(kind: "futureThing")])).d, base.d, "知らない種類は何もしない")
        XCTAssertEqual(try render(project(path, effects: [fx(.brightness, ["amount": 0]), fx(.contrast, ["amount": 1])])).d, base.d, "何もしない値は速い道")
        XCTAssertFalse(project(path, effects: [off]).tracks[0].clips[0].hasActiveEffects)
    }

    func testBrightnessRaisesMeanLuminance() throws {
        let path = try gradientPNG()
        let a = try render(project(path, effects: [])).stats(inner).mean
        let b = try render(project(path, effects: [fx(.brightness, ["amount": 0.3])])).stats(inner).mean
        XCTAssertGreaterThan(b, a + 30)
        let dark = try render(project(path, effects: [fx(.exposure, ["ev": -1])])).stats(inner).mean
        XCTAssertLessThan(dark, a - 10)
    }

    func testContrastAndSaturation() throws {
        let path = try gradientPNG()
        let base = try render(project(path, effects: [])).stats(inner)
        let hi = try render(project(path, effects: [fx(.contrast, ["amount": 2])])).stats(inner)
        XCTAssertGreaterThan(hi.variance, base.variance * 1.5)
        let grey = try render(project(path, effects: [fx(.saturation, ["amount": 0])]))
        for (x, y) in [(60, 60), (100, 100), (140, 70)] { let c = grey.rgb(x, y); XCTAssertLessThanOrEqual(abs(c[0] - c[1]), 2); XCTAssertLessThanOrEqual(abs(c[1] - c[2]), 2) }
    }

    func testMonoMakesRGBEqual() throws {
        let path = try gradientPNG()
        let m = try render(project(path, effects: [fx(.mono, ["amount": 1])]))
        var colourful = 0
        for y in stride(from: 58, to: 142, by: 7) { for x in stride(from: 58, to: 142, by: 7) {
            let c = m.rgb(x, y)
            XCTAssertLessThanOrEqual(max(c[0], c[1], c[2]) - min(c[0], c[1], c[2]), 1, "(\(x),\(y)) \(c)")
            if (max(c[0], c[1], c[2]) - min(c[0], c[1], c[2])) > 0 { colourful += 1 }
        } }
        XCTAssertLessThan(colourful, 20)
        // 元は色がある
        let o = try render(project(path, effects: [])).rgb(60, 60)
        XCTAssertGreaterThan(max(o[0], o[1], o[2]) - min(o[0], o[1], o[2]), 20)
    }

    func testSepiaAndHueChangeColour() throws {
        let path = try gradientPNG()
        let base = try render(project(path, effects: [])).rgb(100, 100)
        let sepia = try render(project(path, effects: [fx(.sepia)])).rgb(100, 100)
        XCTAssertGreaterThan(sepia[0], sepia[2] + 15, "セピアは赤っぽい")
        let hue = try render(project(path, effects: [fx(.hue, ["degrees": 120])])).rgb(100, 100)
        XCTAssertNotEqual(hue, base)
    }

    func testSharpenIncreasesVarianceOfAnEdge() throws {
        // 市松(白黒)のぼかした絵をシャープにすると、分散が増える
        let path = try gradientPNG()
        let blurred = project(path, effects: [fx(.gaussianBlur, ["radius": px(2)])])
        var sharp = blurred
        sharp.tracks[0].clips[0].effects.append(fx(.sharpen, ["amount": 3]))
        let a = try render(blurred).stats(inner).variance, b = try render(sharp).stats(inner).variance
        XCTAssertGreaterThanOrEqual(b, a)
        XCTAssertNotEqual(try render(blurred).d, try render(sharp).d)
    }

    func testVignetteDarkensCornersNotCentre() throws {
        let path = try solidPNG(r: 200, g: 200, b: 200)
        let base = try render(project(path, effects: []))
        let v = try render(project(path, effects: [fx(.vignette, ["intensity": 1.5, "radius": 0.8])]))
        XCTAssertEqual(v.luma(100, 100), base.luma(100, 100), accuracy: 3)
        XCTAssertLessThan(v.luma(58, 58), base.luma(58, 58) - 40, "角が暗くなる")
        XCTAssertEqual(v.rgb(10, 10), base.rgb(10, 10), "クリップの外(背景)は変わらない")
    }

    func testPixelateMakesBlocks() throws {
        let path = try noisePNG()
        func equalPairs(_ p: Pixels) -> Double {
            var eq = 0, n = 0
            for y in 60..<140 { for x in 60..<139 { n += 1; if p.rgb(x, y) == p.rgb(x + 1, y) { eq += 1 } } }
            return Double(eq) / Double(n)
        }
        let base = try render(project(path, effects: []))
        let pix = try render(project(path, effects: [fx(.pixelate, ["size": px(10)])]))
        XCTAssertLessThan(equalPairs(base), 0.05)
        XCTAssertGreaterThan(equalPairs(pix), 0.8, "10px のブロックなら、隣どうしはほぼ同じ色")
    }

    func testGaussianBlurReducesVarianceAndKeepsEdgesBright() throws {
        let path = try noisePNG()
        let a = try render(project(path, effects: [])).stats(inner).variance
        let b = try render(project(path, effects: [fx(.gaussianBlur, ["radius": px(4)])])).stats(inner).variance
        XCTAssertLessThan(b, a * 0.2)
        // 画面いっぱいの絵では、縁が暗くならない(clamp-to-extent)
        var full = project(try solidPNG(r: 200, g: 200, b: 200), effects: [fx(.gaussianBlur, ["radius": px(20)])])
        full.tracks[0].clips[0].scale = 1
        let p = try render(full)
        XCTAssertGreaterThan(p.luma(2, 100), 190, "縁が暗くならない")
        XCTAssertGreaterThan(p.luma(100, 2), 190)
    }

    func testZoomAndMotionBlurReduceVariance() throws {
        let path = try noisePNG()
        let a = try render(project(path, effects: [])).stats(inner).variance
        XCTAssertLessThan(try render(project(path, effects: [fx(.zoomBlur, ["amount": px(30)])])).stats(inner).variance, a * 0.6)
        let mb = try render(project(path, effects: [fx(.motionBlur, ["radius": px(12), "angle": 0])]))
        XCTAssertLessThan(mb.stats(inner).variance, a * 0.6)
    }

    func testGlowSpreadsLightOutsideAndShadowExtendsBeyondTheRect() throws {
        // 白い絵に黒の影: 右下の外側が暗くなる(背景は中間グレー)
        let white = try solidPNG(r: 255, g: 255, b: 255)
        let base = try render(project(white, effects: []))
        let sh = try render(project(white, effects: [fx(.dropShadow, ["dx": px(10), "dy": px(10), "blur": px(4), "opacity": 0.8], color: "#000000")]))
        // 絵は 50〜150。右下の外 (153,153) と (150..160,100) あたりに影
        XCTAssertLessThan(sh.luma(155, 155), base.luma(155, 155) - 40)
        XCTAssertEqual(sh.luma(30, 30), base.luma(30, 30), accuracy: 2, "左上の外は影がない")
        XCTAssertEqual(sh.luma(100, 100), base.luma(100, 100), accuracy: 2, "絵そのものは変わらない")
        // 色つきの影
        let col = try render(project(white, effects: [fx(.dropShadow, ["dx": px(10), "dy": px(10), "blur": 0, "opacity": 1], color: "#ff0000")]))
        let c = col.rgb(155, 155)
        XCTAssertGreaterThan(c[0], 200); XCTAssertLessThan(c[1], 40)
        // グロー: 絵の外が明るくなる
        let dark = project(white, effects: [fx(.glow, ["radius": px(20), "intensity": 1])], bg: "#000000")
        let g = try render(dark), g0 = try render(project(white, effects: [], bg: "#000000"))
        XCTAssertGreaterThan(g.luma(46, 100), g0.luma(46, 100) + 20, "縁の外に光がにじむ")
        XCTAssertEqual(g.luma(10, 10), g0.luma(10, 10), accuracy: 3)
    }

    func testOutlineGrowsTheShape() throws {
        let red = try solidPNG(r: 255, g: 0, b: 0)
        let base = try render(project(red, effects: [], bg: "#000000"))
        let ol = try render(project(red, effects: [fx(.outline, ["width": px(6)], color: "#ffffff")], bg: "#000000"))
        XCTAssertEqual(base.luma(47, 100), 0, accuracy: 1)
        XCTAssertGreaterThan(ol.luma(47, 100), 200, "絵の外 3px が白い縁")
        XCTAssertEqual(ol.luma(30, 100), 0, accuracy: 2, "縁より外は黒のまま")
        XCTAssertEqual(ol.rgb(100, 100), [255, 0, 0], "絵は赤のまま")
    }

    func testEffectsAreDeterministicAndRespectOpacity() throws {
        let path = try gradientPNG()
        var p = project(path, effects: [fx(.sepia), fx(.vignette), fx(.dropShadow)])
        XCTAssertEqual(try render(p).d, try render(p).d)
        p.tracks[0].clips[0].opacity = 0.5
        let half = try render(p), full = try render(project(path, effects: [fx(.sepia), fx(.vignette), fx(.dropShadow)]))
        let bg = try render(project(path, effects: [])).luma(5, 5)
        XCTAssertEqual(half.luma(100, 100), (full.luma(100, 100) + bg) / 2, accuracy: 6, "不透明度はエフェクトの後にかかる")
    }

    func testEffectsWorkOnTextAndRotatedClipsAndTransitions() throws {
        var t = Clip(); t.id = "t"; t.type = .text; t.text = "テスト"; t.fontSize = 60; t.start = 0; t.duration = 3; t.x = 0.5; t.y = 0.5
        t.effects = [fx(.dropShadow), fx(.glow)]
        var p = Project(); p.width = 320; p.height = 180; p.characters = []
        var tr = Track(name: "L"); tr.clips = [t]; p.tracks = [tr]
        let plain = try render({ var q = p; q.tracks[0].clips[0].effects = []; return q }())
        let fxed = try render(p)
        XCTAssertNotEqual(plain.d, fxed.d)
        // 回転 + トランジション + クリップのぼかしと一緒でも描ける
        p.tracks[0].clips[0].rotation = 30
        p.tracks[0].clips[0].transitionIn = Transition(.fade, duration: 1)
        p.tracks[0].clips[0].blur = 3
        XCTAssertNotNil(Renderer(project: p, assets: RenderAssets()).renderImage(t: 0.3))
    }

    // MARK: 引数・範囲

    func testParamClampingAndDefaults() {
        var e = Effect(.brightness)
        XCTAssertEqual(e.params["amount"], 0.2)
        e.params["amount"] = 99
        XCTAssertEqual(e.value("amount"), 1, "範囲に収める")
        e.params["amount"] = -99
        XCTAssertEqual(e.value("amount"), -1)
        e.params["amount"] = .nan
        XCTAssertEqual(e.value("amount"), 0.2, "NaN は既定値")
        XCTAssertEqual(Effect(kind: "brightness").value("amount"), 0.2, "未設定は既定値")
        XCTAssertEqual(Effect(kind: "futureThing", params: ["k": 7]).value("k"), 7)
        // 仕様の範囲
        XCTAssertEqual(EffectKind.pixelate.spec("size")!.range, 2...100)
        XCTAssertEqual(EffectKind.contrast.spec("amount")!.range, 0...3)
        XCTAssertEqual(EffectKind.outline.spec("width")!.range, 1...30)
        XCTAssertEqual(EffectKind.motionBlur.params.map(\.key), ["radius", "angle"])
        XCTAssertEqual(EffectKind.allCases.count, 19)
        for k in EffectKind.allCases { for s in k.params { XCTAssertTrue(s.range.contains(s.defaultValue), "\(k) \(s.key)") } }
    }

    // MARK: ファイル

    func fixtureURL(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "ymproj", subdirectory: "Fixtures"))
    }

    func testUntouchedClipWritesNoEffectsKey() throws {
        var c = Clip(); c.type = .image; c.src = "/a.png"
        var p = Project(); p.tracks = [Track(name: "t")]; p.tracks[0].clips = [c]
        XCTAssertFalse(String(decoding: try p.encoded(), as: UTF8.self).contains("effects"))
    }

    func testEffectsFixtureRoundTripsAndKeepsUnknowns() throws {
        let p1 = try Project.load(from: fixtureURL("effects"))
        let img = p1.allClips.first { $0.id == "eimg" }!
        XCTAssertEqual(img.effects.map(\.kind), ["brightness", "dropShadow", "outline", "someFutureEffect"])
        XCTAssertEqual(img.effects[0].params, ["amount": 0.3]); XCTAssertTrue(img.effects[0].enabled)
        XCTAssertEqual(img.effects[1].color, "#112233")
        XCTAssertFalse(img.effects[2].enabled)
        XCTAssertEqual(img.effects[2].extra["futureEffectKey"], .array([.number(1), .number(2)]))
        XCTAssertNil(img.effects[3].known); XCTAssertEqual(img.effects[3].params, ["strength": 3])
        XCTAssertEqual(img.keyframes["fx.0.amount"]?.count, 2)
        XCTAssertEqual(img.extra["futureClipKey"], .string("keep"))
        // 範囲外の値は読むときは保ち、使うときに収める
        let txt = p1.allClips.first { $0.id == "etxt" }!
        XCTAssertEqual(txt.effects[1].params["radius"], 99999); XCTAssertEqual(txt.effects[1].value("radius"), 100)
        // 読めないエフェクト列は捨てずに書き戻す
        let bad = p1.allClips.first { $0.id == "ebad" }!
        XCTAssertTrue(bad.effects.isEmpty); XCTAssertEqual(bad.extra["effects"], .string("this is not an effect list"))
        // 往復で同じ
        let data = try p1.encoded()
        let p2 = try Project.decode(from: data)
        XCTAssertEqual(p1, p2)
        XCTAssertEqual(try p2.encoded(), data)
        let s = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(s.contains("\"enabled\" : false") || s.contains("\"enabled\":false"))
        XCTAssertEqual(s.components(separatedBy: "enabled").count - 1, 1, "enabled は無効のときだけ書く")
    }

    func testOldFixturesDoNotGainEffects() throws {
        for n in ["rich", "electron-made", "keyframes", "transitions"] {
            let p = try Project.load(from: fixtureURL(n))
            XCTAssertTrue(p.allClips.allSatisfy { $0.effects.isEmpty }, n)
            XCTAssertFalse(String(decoding: try p.encoded(), as: UTF8.self).contains("\"effects\""), n)
        }
    }

    // MARK: キーフレーム

    func testKeyframedEffectParamsInterpolateAndRender() throws {
        let path = try gradientPNG()
        var p = project(path, effects: [fx(.brightness, ["amount": 0])])
        var c = p.tracks[0].clips[0]
        XCTAssertTrue(Animation.keys(for: c).contains("fx.0.amount"))
        // 0 秒 = 0、2 秒 = 0.6 の直線
        c.keyframes["fx.0.amount"] = [Keyframe(t: 0, v: 0), Keyframe(t: 2, v: 0.6)]
        XCTAssertEqual(Animation.value(of: "fx.0.amount", in: c, at: 1), 0.3, accuracy: 1e-9)
        XCTAssertEqual(EffectPipeline.resolve(c, atClipTime: 1).first?.v("amount") ?? -1, 0.3, accuracy: 1e-9)
        XCTAssertTrue(EffectPipeline.resolve(c, atClipTime: 0).isEmpty, "0 の明るさは何もしない")
        p.tracks[0].clips[0] = c
        let m0 = try render(p, t: 0.0).stats(inner).mean, m1 = try render(p, t: 1.0).stats(inner).mean, m2 = try render(p, t: 2.0).stats(inner).mean
        XCTAssertLessThan(m0, m1); XCTAssertLessThan(m1, m2)
        XCTAssertEqual(m0, try render(project(path, effects: []), t: 0).stats(inner).mean, accuracy: 0.01)
        // 範囲を超えるキーは使うときに収める
        c.keyframes["fx.0.amount"] = [Keyframe(t: 0, v: 5)]
        XCTAssertEqual(EffectPipeline.resolve(c, atClipTime: 1).first?.v("amount") ?? -1, 1, accuracy: 1e-9)
    }

    func testKeyframingGaussianBlurRadiusAndSaturationAndContrastAndShadowOpacity() throws {
        var c = Clip(); c.type = .image
        c.effects = [Effect(.contrast), Effect(.saturation), Effect(.gaussianBlur), Effect(.dropShadow)]
        for (i, key) in [(0, "amount"), (1, "amount"), (2, "radius"), (3, "opacity")] {
            let k = EffectKey.make(i, key)
            XCTAssertTrue(Animation.keys(for: c).contains(k), k)
            XCTAssertTrue(KeyframeEditing.toggle(&c, key: k, at: 0, tolerance: 0.01), k)
            KeyframeEditing.setValue(&c, key: k, 99999, at: 1, tolerance: 0.01)
            let top = c.effects[i].known!.spec(key)!.range.upperBound
            XCTAssertEqual(Animation.value(of: k, in: c, at: 1), top, "\(k) は範囲に収まる")
        }
        // 最後のキーを消すと、その値を設定値にする
        let k = EffectKey.make(2, "radius")
        XCTAssertTrue(KeyframeEditing.toggle(&c, key: k, at: 1, tolerance: 0.01))
        XCTAssertTrue(KeyframeEditing.toggle(&c, key: k, at: 0, tolerance: 0.01))
        XCTAssertNil(c.keyframes[k])
        XCTAssertEqual(c.effects[2].params["radius"], 8)
        // 全部消す
        KeyframeEditing.clearAll(&c, at: 0)
        XCTAssertTrue(c.keyframes.isEmpty)
        XCTAssertEqual(Animation.label(of: EffectKey.make(3, "dx"), in: c), "ドロップシャドウ 横のずれ（px）")
    }

    // MARK: 編集

    func testAddRemoveMoveRemapKeyframes() {
        var c = Clip(); c.type = .video
        EffectEditing.add(&c, .brightness); EffectEditing.add(&c, .gaussianBlur); EffectEditing.add(&c, .sepia)
        XCTAssertEqual(c.effects.map(\.kind), ["brightness", "gaussianBlur", "sepia"])
        KeyframeEditing.toggle(&c, key: "fx.1.radius", at: 0, tolerance: 0.01)
        KeyframeEditing.toggle(&c, key: "fx.0.amount", at: 0, tolerance: 0.01)
        KeyframeEditing.toggle(&c, key: "x", at: 0, tolerance: 0.01)
        // 先頭を後ろへ → ぼかしが 0、明るさが 1
        XCTAssertTrue(EffectEditing.move(&c, at: 0, by: 1))
        XCTAssertEqual(c.effects.map(\.kind), ["gaussianBlur", "brightness", "sepia"])
        XCTAssertNotNil(c.keyframes["fx.0.radius"]); XCTAssertNotNil(c.keyframes["fx.1.amount"]); XCTAssertNil(c.keyframes["fx.1.radius"])
        XCTAssertFalse(EffectEditing.move(&c, at: 0, by: -1), "端は動かない")
        XCTAssertFalse(EffectEditing.move(&c, at: 2, by: 1))
        // 先頭を消す → 明るさが 0 に詰まる。ぼかしのキーは消える
        XCTAssertTrue(EffectEditing.remove(&c, at: 0))
        XCTAssertEqual(c.effects.map(\.kind), ["brightness", "sepia"])
        XCTAssertNotNil(c.keyframes["fx.0.amount"]); XCTAssertNil(c.keyframes["fx.0.radius"]); XCTAssertNil(c.keyframes["fx.1.amount"])
        XCTAssertNotNil(c.keyframes["x"], "エフェクト以外のキーは触らない")
        XCTAssertFalse(EffectEditing.remove(&c, at: 5))
        // 初期値に戻す(その引数のキーも消す)
        c.effects[0].params["amount"] = -0.5
        XCTAssertTrue(EffectEditing.reset(&c, at: 0))
        XCTAssertEqual(c.effects[0].params["amount"], 0.2); XCTAssertNil(c.keyframes["fx.0.amount"])
        XCTAssertFalse(EffectEditing.reset(&c, at: 0), "すでに初期値")
        // 有効 / 色
        XCTAssertTrue(EffectEditing.setEnabled(&c, at: 1, false)); XCTAssertFalse(EffectEditing.setEnabled(&c, at: 1, false))
        EffectEditing.add(&c, .outline)
        XCTAssertTrue(EffectEditing.setColor(&c, at: 2, "#ff0000")); XCTAssertFalse(EffectEditing.setColor(&c, at: 2, "#ff0000"))
        XCTAssertFalse(EffectEditing.setColor(&c, at: 0, "#ff0000"), "色を持たない種類")
        // すべて外す
        XCTAssertTrue(EffectEditing.clear(&c)); XCTAssertTrue(c.effects.isEmpty); XCTAssertNotNil(c.keyframes["x"])
        XCTAssertFalse(EffectEditing.clear(&c))
        // 音声・ぼかし範囲には付かない
        var a = Clip(); a.type = .audio
        XCTAssertFalse(EffectEditing.add(&a, .sepia)); XCTAssertTrue(a.effects.isEmpty)
        var b = Clip(); b.type = .blur
        XCTAssertFalse(EffectEditing.add(&b, .sepia))
    }

    func testPresets() {
        XCTAssertEqual(EffectPreset.allCases.map(\.title), ["ビンテージ", "白黒映画", "夢のような", "強調", "モザイク全体"])
        var c = Clip(); c.type = .image
        XCTAssertTrue(EffectPreset.vintage.apply(to: &c))
        XCTAssertEqual(c.effects.map(\.kind), ["sepia", "vignette", "contrast"])
        XCTAssertTrue(EffectPreset.noirFilm.apply(to: &c))
        XCTAssertEqual(c.effects.suffix(3).map(\.kind), ["mono", "contrast", "vignette"])
        var d = Clip(); d.type = .text
        EffectPreset.dreamy.apply(to: &d); XCTAssertEqual(d.effects.map(\.kind), ["glow", "brightness"])
        var e = Clip(); e.type = .video
        EffectPreset.punchy.apply(to: &e); XCTAssertEqual(e.effects.map(\.kind), ["sharpen", "saturation"])
        EffectPreset.mosaicAll.apply(to: &e); XCTAssertEqual(e.effects.last?.kind, "pixelate")
        for pr in EffectPreset.allCases { for fx in pr.effects { for s in fx.known!.params { XCTAssertTrue(s.range.contains(fx.value(s.key))) } } }
        var a = Clip(); a.type = .audio
        XCTAssertFalse(EffectPreset.vintage.apply(to: &a))
    }

    func testSplitKeepsEffectsAndKeys() throws {
        var c = Clip(); c.id = "s"; c.type = .image; c.start = 0; c.duration = 4
        EffectEditing.add(&c, .brightness)
        c.keyframes["fx.0.amount"] = [Keyframe(t: 0, v: 0), Keyframe(t: 4, v: 1)]
        var p = Project(); p.tracks = [Track(name: "t")]; p.tracks[0].clips = [c]
        let r = try XCTUnwrap(ClipEditing.split(in: p, clipId: "s", at: 2))
        let clips = r.project.tracks[0].clips
        XCTAssertEqual(clips.count, 2)
        XCTAssertTrue(clips.allSatisfy { $0.effects.count == 1 })
        XCTAssertEqual(Animation.value(of: "fx.0.amount", in: clips[1], at: 0), 0.5, accuracy: 1e-9)
    }
}
