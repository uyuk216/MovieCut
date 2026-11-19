import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import MovieCutCore

/// ブレンドモード: ファイル形式の往復と、描画(乗算)の効き。
final class BlendModeTests: XCTestCase {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("blend-tests-\(UUID().uuidString)")
    override func setUpWithError() throws { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func testRoundTrip() throws {
        var c = Clip(); c.blendMode = .multiply
        let data = try JSONEncoder().encode(c)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"blendMode\":\"multiply\""), json)
        XCTAssertEqual(try JSONDecoder().decode(Clip.self, from: data).blendMode, .multiply)

        // 未設定なら書かない
        let plain = try JSONEncoder().encode(Clip())
        XCTAssertFalse(String(data: plain, encoding: .utf8)?.contains("blendMode") ?? true)

        // 知らない名前は捨てずに extra へ(値は blendMode にならない)
        let unknown = try JSONDecoder().decode(Clip.self, from: Data(#"{"id":"x","type":"image","blendMode":"weird"}"#.utf8))
        XCTAssertNil(unknown.blendMode)
        XCTAssertEqual(unknown.extra["blendMode"], .string("weird"))
        let rewritten = try JSONEncoder().encode(unknown)
        XCTAssertTrue(String(data: rewritten, encoding: .utf8)?.contains("\"blendMode\":\"weird\"") ?? false)
    }

    func testAllCasesHaveLabelsAndMapping() {
        XCTAssertEqual(ClipBlendMode.allCases.count, 17)
        for m in ClipBlendMode.allCases { XCTAssertFalse(m.label.isEmpty) }
        XCTAssertEqual(ClipBlendMode.multiply.cgBlendMode, .multiply)
        XCTAssertEqual(ClipBlendMode.screen.cgBlendMode, .screen)
        XCTAssertEqual(ClipBlendMode.plusLighter.cgBlendMode, .plusLighter)
        // 減算: ラベルと、画素合成が必要なのは減算だけであること
        XCTAssertEqual(ClipBlendMode.subtract.label, "減算")
        XCTAssertTrue(ClipBlendMode.subtract.requiresLayerComposite)
        for m in ClipBlendMode.allCases where m != .subtract { XCTAssertFalse(m.requiresLayerComposite, "\(m)") }
    }

    func testSubtractRoundTrip() throws {
        var c = Clip(); c.blendMode = .subtract
        let data = try JSONEncoder().encode(c)
        XCTAssertTrue((String(data: data, encoding: .utf8) ?? "").contains("\"blendMode\":\"subtract\""))
        XCTAssertEqual(try JSONDecoder().decode(Clip.self, from: data).blendMode, .subtract)
    }

    // MARK: 描画

    private func solidPNG(_ name: String, r: UInt8, g: UInt8, b: UInt8, size: Int = 256) throws -> String {
        let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1))
        c.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let url = tmp.appendingPathComponent(name)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, c.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url.path
    }

    private func imageClip(_ path: String, blend: ClipBlendMode? = nil) -> Clip {
        var c = Clip(); c.type = .image; c.src = path; c.start = 0; c.duration = 2
        c.x = 0.5; c.y = 0.5; c.scale = 1; c.opacity = 1; c.blendMode = blend
        return c
    }

    private func centerRGB(_ p: Project) throws -> (Int, Int, Int) {
        let img = try XCTUnwrap(Renderer(project: p, assets: RenderAssets()).renderImage(t: 0.5))
        var d = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let ctx = CGContext(data: &d, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        let i = ((img.height / 2) * img.width + img.width / 2) * 4
        return (Int(d[i]), Int(d[i + 1]), Int(d[i + 2]))
    }

    /// 任意の画素(左上原点のつもりで、中心対称な検証に使う)
    private func rgb(_ p: Project, x: Int, y: Int) throws -> (Int, Int, Int) {
        let img = try XCTUnwrap(Renderer(project: p, assets: RenderAssets()).renderImage(t: 0.5))
        var d = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let ctx = CGContext(data: &d, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        let i = (y * img.width + x) * 4
        return (Int(d[i]), Int(d[i + 1]), Int(d[i + 2]))
    }

    /// 下・上とも任意色の重ね(64×64、上は不透明度・拡大を指定可)
    private func twoColorProject(bottom: (UInt8, UInt8, UInt8), top: (UInt8, UInt8, UInt8),
                                 blend: ClipBlendMode?, topOpacity: Double = 1, topScale: Double = 1,
                                 bg: String = "#000000") throws -> Project {
        var p = Project(); p.width = 64; p.height = 64; p.bg = bg; p.characters = []
        var b = Track(name: "下")
        b.clips = [imageClip(try solidPNG("b\(bottom.0)-\(bottom.1)-\(bottom.2).png", r: bottom.0, g: bottom.1, b: bottom.2))]
        var t = Track(name: "上")
        var tc = imageClip(try solidPNG("t\(top.0)-\(top.1)-\(top.2).png", r: top.0, g: top.1, b: top.2), blend: blend)
        tc.opacity = topOpacity; tc.scale = topScale
        t.clips = [tc]
        p.tracks = [b, t]
        return p
    }

    private func stackedProject(topBlend: ClipBlendMode?) throws -> Project {
        var p = Project(); p.width = 64; p.height = 64; p.bg = "#000000"; p.characters = []
        var bottom = Track(name: "下"); bottom.clips = [imageClip(try solidPNG("red.png", r: 255, g: 0, b: 0))]
        var top = Track(name: "上"); top.clips = [imageClip(try solidPNG("gray.png", r: 128, g: 128, b: 128), blend: topBlend)]
        p.tracks = [bottom, top]
        return p
    }

    func testRenderMultiply() throws {
        // 通常: 上の灰色がそのまま出る
        let normal = try centerRGB(stackedProject(topBlend: nil))
        XCTAssertEqual(normal.0, 128); XCTAssertEqual(normal.1, 128); XCTAssertEqual(normal.2, 128)
        // 乗算: 赤 × 灰色 = (128, 0, 0)
        let mul = try centerRGB(stackedProject(topBlend: .multiply))
        XCTAssertEqual(mul.0, 128, accuracy: 2); XCTAssertEqual(mul.1, 0, accuracy: 2); XCTAssertEqual(mul.2, 0, accuracy: 2)
        // スクリーン: 赤 ∪ 灰色 = (255, 128, 128)
        let scr = try centerRGB(stackedProject(topBlend: .screen))
        XCTAssertEqual(scr.0, 255, accuracy: 2); XCTAssertEqual(scr.1, 128, accuracy: 2); XCTAssertEqual(scr.2, 128, accuracy: 2)
    }

    // W3-21 追加検証: その他の代表モードも画素で確かめる(下 = 赤 (255,0,0)、上 = 灰 128)
    func testRenderMoreModes() throws {
        let dark = try centerRGB(stackedProject(topBlend: .darken))       // 比較（暗）: 成分ごとの小さい方
        XCTAssertEqual(dark.0, 128, accuracy: 2); XCTAssertEqual(dark.1, 0, accuracy: 2); XCTAssertEqual(dark.2, 0, accuracy: 2)
        let light = try centerRGB(stackedProject(topBlend: .lighten))    // 比較（明）: 成分ごとの大きい方
        XCTAssertEqual(light.0, 255, accuracy: 2); XCTAssertEqual(light.1, 128, accuracy: 2); XCTAssertEqual(light.2, 128, accuracy: 2)
        let diff = try centerRGB(stackedProject(topBlend: .difference))  // 差分: 絶対差
        XCTAssertEqual(diff.0, 127, accuracy: 2); XCTAssertEqual(diff.1, 128, accuracy: 2); XCTAssertEqual(diff.2, 128, accuracy: 2)
        let over = try centerRGB(stackedProject(topBlend: .overlay))     // オーバーレイ: 下が 1 の所は 1、0 の所は 0
        XCTAssertEqual(over.0, 255, accuracy: 2); XCTAssertEqual(over.1, 0, accuracy: 2); XCTAssertEqual(over.2, 0, accuracy: 2)
        let plus = try centerRGB(stackedProject(topBlend: .plusLighter)) // 加算: 255+128 は 255 に飽和、0+128 = 128
        XCTAssertEqual(plus.0, 255, accuracy: 2); XCTAssertEqual(plus.1, 128, accuracy: 2); XCTAssertEqual(plus.2, 128, accuracy: 2)
    }

    // MARK: 減算(定義: clamp(下 − 上 + 1.0)、Photoshop / Premiere と同じ)

    func testRenderSubtract() throws {
        // 下 = 赤 (255,0,0)、上 = 灰 128: R は 255−128+255 で 255 にクランプ、G・B は 0−128+255 = 127
        let sub = try centerRGB(twoColorProject(bottom: (255, 0, 0), top: (128, 128, 128), blend: .subtract))
        XCTAssertEqual(sub.0, 255, accuracy: 2); XCTAssertEqual(sub.1, 127, accuracy: 2); XCTAssertEqual(sub.2, 127, accuracy: 2)
        // クランプの無い中間値: (60,80,100) − (100,120,140) + 255 = (215,215,215)
        let mid = try centerRGB(twoColorProject(bottom: (60, 80, 100), top: (100, 120, 140), blend: .subtract))
        XCTAssertEqual(mid.0, 215, accuracy: 2); XCTAssertEqual(mid.1, 215, accuracy: 2); XCTAssertEqual(mid.2, 215, accuracy: 2)
        // 下限クランプ: 黒 − 白 + 255 = 0(通常合成なら白になる所)
        let low = try centerRGB(twoColorProject(bottom: (0, 0, 0), top: (255, 255, 255), blend: .subtract))
        XCTAssertEqual(low.0, 0, accuracy: 2); XCTAssertEqual(low.1, 0, accuracy: 2); XCTAssertEqual(low.2, 0, accuracy: 2)
        // 上限クランプ: 白 − 黒 + 255 = 510 → 255
        let high = try centerRGB(twoColorProject(bottom: (255, 255, 255), top: (0, 0, 0), blend: .subtract))
        XCTAssertEqual(high.0, 255, accuracy: 2); XCTAssertEqual(high.1, 255, accuracy: 2); XCTAssertEqual(high.2, 255, accuracy: 2)
        // 同じ色同士: 色 − 色 + 255 = 255(白)になるのが減算の特徴
        let same = try centerRGB(twoColorProject(bottom: (90, 160, 30), top: (90, 160, 30), blend: .subtract))
        XCTAssertEqual(same.0, 255, accuracy: 2); XCTAssertEqual(same.1, 255, accuracy: 2); XCTAssertEqual(same.2, 255, accuracy: 2)
    }

    func testRenderSubtractOpacityAndExtent() throws {
        // 不透明度 0.5: 台紙の α=0.5 でブレンド色と下を半々: R は 255 のまま、G・B は (0−128+255)×0.5 ≒ 64
        let half = try centerRGB(twoColorProject(bottom: (255, 0, 0), top: (128, 128, 128), blend: .subtract, topOpacity: 0.5))
        XCTAssertEqual(half.0, 255, accuracy: 3); XCTAssertEqual(half.1, 64, accuracy: 3); XCTAssertEqual(half.2, 64, accuracy: 3)
        // 上が中央の半分だけ(拡大 0.5): 中央は減算結果、隅は下の赤のまま(台紙の外は触らない・位置が合っている)
        let p = try twoColorProject(bottom: (255, 0, 0), top: (128, 128, 128), blend: .subtract, topScale: 0.5)
        let center = try rgb(p, x: 32, y: 32)
        XCTAssertEqual(center.0, 255, accuracy: 2); XCTAssertEqual(center.1, 127, accuracy: 2); XCTAssertEqual(center.2, 127, accuracy: 2)
        for (x, y) in [(4, 4), (60, 4), (4, 60), (60, 60)] {
            let corner = try rgb(p, x: x, y: y)
            XCTAssertEqual(corner.0, 255, accuracy: 2, "隅 (\(x),\(y))"); XCTAssertEqual(corner.1, 0, accuracy: 2, "隅 (\(x),\(y))"); XCTAssertEqual(corner.2, 0, accuracy: 2, "隅 (\(x),\(y))")
        }
        // 下が透明(背景なし・下クリップ無し)では、減算でも上そのものが出る
        var tp = Project(); tp.width = 64; tp.height = 64; tp.bg = "transparent"; tp.characters = []
        var only = Track(name: "上"); only.clips = [imageClip(try solidPNG("only.png", r: 128, g: 128, b: 128), blend: .subtract)]
        tp.tracks = [only]
        let alone = try centerRGB(tp)
        XCTAssertEqual(alone.0, 128, accuracy: 2); XCTAssertEqual(alone.1, 128, accuracy: 2); XCTAssertEqual(alone.2, 128, accuracy: 2)
    }

    /// 減算の 1 画素計算: 端値と半透明の合成式を直接確かめる(事前乗算 RGBA)
    func testSubtractBlendPixel() {
        // 両方不透明: 定義どおり
        var o = SubtractBlend.blendPixel(br: 255, bg: 0, bb: 0, ba: 255, sr: 128, sg: 128, sb: 128, sa: 255)
        XCTAssertEqual(Int(o.r), 255); XCTAssertEqual(Int(o.g), 127); XCTAssertEqual(Int(o.b), 127); XCTAssertEqual(Int(o.a), 255)
        // 上が透明 → 下そのまま / 下が透明 → 上そのまま
        o = SubtractBlend.blendPixel(br: 10, bg: 20, bb: 30, ba: 200, sr: 0, sg: 0, sb: 0, sa: 0)
        XCTAssertEqual(Int(o.r), 10); XCTAssertEqual(Int(o.g), 20); XCTAssertEqual(Int(o.b), 30); XCTAssertEqual(Int(o.a), 200)
        o = SubtractBlend.blendPixel(br: 0, bg: 0, bb: 0, ba: 0, sr: 40, sg: 50, sb: 60, sa: 90)
        XCTAssertEqual(Int(o.r), 40); XCTAssertEqual(Int(o.g), 50); XCTAssertEqual(Int(o.b), 60); XCTAssertEqual(Int(o.a), 90)
        // 上が半透明(事前乗算 50/α100 → 非事前乗算 0.5)、下は不透明 200: ブレンド色は 200/255−0.5+1 で 1 にクランプ、
        // 合成 = αs×1 + (1−αs)×(200/255) ≒ 0.869 → 222、α は 255
        o = SubtractBlend.blendPixel(br: 200, bg: 200, bb: 200, ba: 255, sr: 50, sg: 50, sb: 50, sa: 100)
        XCTAssertEqual(Int(o.r), 222, accuracy: 1); XCTAssertEqual(Int(o.a), 255)
        // 下が半透明(事前乗算 64/α128 → 0.5)、上は不透明の白: ブレンド色 0.5−1+1 = 0.5、
        // 合成 = (1−αb)×1 + αb×0.5 ≒ 0.749 → 191、α は 255
        o = SubtractBlend.blendPixel(br: 64, bg: 64, bb: 64, ba: 128, sr: 255, sg: 255, sb: 255, sa: 255)
        XCTAssertEqual(Int(o.r), 191, accuracy: 1); XCTAssertEqual(Int(o.a), 255)
    }
}
