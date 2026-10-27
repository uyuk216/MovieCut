import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import MovieCutCore

/// 回転・反転・切り抜き・キーフレームの描画(画素単位)。
final class TransformRendererTests: XCTestCase {
    struct Pixels {
        let w: Int, h: Int
        var d: [UInt8]
        func rgb(_ x: Int, _ y: Int) -> [Int] { let i = (y * w + x) * 4; return [Int(d[i]), Int(d[i + 1]), Int(d[i + 2])] }
    }

    func pixels(_ img: CGImage) -> Pixels {
        var d = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let c = CGContext(data: &d, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return Pixels(w: img.width, h: img.height, d: d)
    }

    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("transform-tests-\(UUID().uuidString)")
    override func setUpWithError() throws { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func writePNG(_ img: CGImage, _ name: String) throws -> String {
        let url = tmp.appendingPathComponent(name)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, img, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url.path
    }

    /// 不透明なノイズ画像(各画素が違う色 = 画素の移動が全部見える)
    func noisePNG(size: Int) throws -> (path: String, src: Pixels) {
        var rng = SystemRandomNumberGenerator()
        var d = [UInt8](repeating: 255, count: size * size * 4)
        for i in 0..<(size * size) { d[i * 4] = .random(in: 0...255, using: &rng); d[i * 4 + 1] = .random(in: 0...255, using: &rng); d[i * 4 + 2] = .random(in: 0...255, using: &rng) }
        let img = d.withUnsafeMutableBytes { raw -> CGImage in
            let c = CGContext(data: raw.baseAddress, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            return c.makeImage()!
        }
        let path = try writePNG(img, "noise\(size).png")
        return (path, pixels(img))
    }

    func solidPNG(_ name: String, r: UInt8, g: UInt8, b: UInt8, size: Int = 20) throws -> String {
        let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1))
        c.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return try writePNG(c.makeImage()!, name)
    }

    func project(w: Int, h: Int, clips: [Clip], bg: String = "#000000") -> Project {
        var p = Project(); p.width = w; p.height = h; p.bg = bg; p.characters = []
        var tr = Track(name: "L1"); tr.clips = clips; p.tracks = [tr]
        return p
    }

    func imageClip(_ path: String, start: Double = 0, dur: Double = 4) -> Clip {
        var c = Clip(); c.id = "i"; c.type = .image; c.src = path; c.start = start; c.duration = dur; c.x = 0.5; c.y = 0.5; c.scale = 1
        return c
    }

    func render(_ p: Project, t: Double = 0.5) throws -> Pixels {
        pixels(try XCTUnwrap(Renderer(project: p, assets: RenderAssets()).renderImage(t: t)))
    }

    // MARK: 回転(画素ぴったり)

    func testRotate90_180_270ArePixelExactAndClockwise() throws {
        let N = 32
        let (path, src) = try noisePNG(size: N)
        func rotated(_ deg: Double?) throws -> Pixels {
            var c = imageClip(path); c.rotation = deg
            return try render(project(w: N, h: N, clips: [c]))
        }
        // 回転なし = 元の画像そのまま
        let base = try rotated(nil)
        for y in 0..<N { for x in 0..<N { XCTAssertEqual(base.rgb(x, y), src.rgb(x, y)) } }
        let r90 = try rotated(90), r180 = try rotated(180), r270 = try rotated(270)
        var bad = 0
        for y in 0..<N { for x in 0..<N {
            if r90.rgb(x, y) != src.rgb(y, N - 1 - x) { bad += 1 }        // 時計回り 90: 元の (sx, sy) → (N-1-sy, sx)
            if r180.rgb(x, y) != src.rgb(N - 1 - x, N - 1 - y) { bad += 1 }
            if r270.rgb(x, y) != src.rgb(N - 1 - y, x) { bad += 1 }       // 時計回り 270 = 反時計回り 90
        } }
        XCTAssertEqual(bad, 0)
        // -90 は 270 と同じ
        let rm = try rotated(-90)
        XCTAssertEqual(rm.d, r270.d)
    }

    func testRotationKeepsTheAnchor() throws {
        // 中心(x, y)は回転しても動かない: 20×20 の赤を 200×100 の (0.25, 0.5) に置いて、45 度回す
        let red = try solidPNG("red.png", r: 255, g: 0, b: 0)
        var c = imageClip(red); c.x = 0.25; c.y = 0.5; c.scale = 0.2        // 一辺 20px
        c.rotation = 45
        let px = try render(project(w: 200, h: 100, clips: [c]))
        XCTAssertEqual(px.rgb(50, 50), [255, 0, 0])
        XCTAssertEqual(px.rgb(50 + 11, 50), [255, 0, 0])          // 45 度の菱形は対角が √2 倍(半径 14)
        XCTAssertEqual(px.rgb(50 + 8, 50 + 8), [0, 0, 0])         // 回すと元の角の近く(対角線の外)は空く
        XCTAssertEqual(px.rgb(150, 50), [0, 0, 0])
    }

    func testFlipsArePixelExact() throws {
        let N = 32
        let (path, src) = try noisePNG(size: N)
        var h = imageClip(path); h.flipH = true
        var v = imageClip(path); v.flipV = true
        var hv = imageClip(path); hv.flipH = true; hv.flipV = true
        let ph = try render(project(w: N, h: N, clips: [h])), pv = try render(project(w: N, h: N, clips: [v])), phv = try render(project(w: N, h: N, clips: [hv]))
        var bad = 0
        for y in 0..<N { for x in 0..<N {
            if ph.rgb(x, y) != src.rgb(N - 1 - x, y) { bad += 1 }
            if pv.rgb(x, y) != src.rgb(x, N - 1 - y) { bad += 1 }
            if phv.rgb(x, y) != src.rgb(N - 1 - x, N - 1 - y) { bad += 1 }
        } }
        XCTAssertEqual(bad, 0)
        // 反転 + 回転 90 の順序: 反転してから回す
        var hr = imageClip(path); hr.flipH = true; hr.rotation = 90
        let phr = try render(project(w: N, h: N, clips: [hr]))
        var bad2 = 0
        for y in 0..<N { for x in 0..<N {
            // 反転後の画像 f(sx, sy) = src(N-1-sx, sy) を時計回り 90: out(x, y) = f(y, N-1-x)
            if phr.rgb(x, y) != src.rgb(N - 1 - y, N - 1 - x) { bad2 += 1 }
        } }
        XCTAssertEqual(bad2, 0)
    }

    func testCropShowsOnlyKeptPartCenteredOnTheAnchor() throws {
        let N = 32
        let (path, src) = try noisePNG(size: N)
        var c = imageClip(path); c.crop = Crop(l: 0.5, t: 0, r: 0, b: 0)       // 右半分だけ残す(幅 16)
        let px = try render(project(w: N, h: N, clips: [c]))
        var bad = 0
        for y in 0..<N { for x in 8..<24 where px.rgb(x, y) != src.rgb(x + 8, y) { bad += 1 } }
        XCTAssertEqual(bad, 0)
        // 切り抜いた外は背景
        XCTAssertEqual(px.rgb(3, 5), [0, 0, 0]); XCTAssertEqual(px.rgb(28, 5), [0, 0, 0])
        // 上下も
        var c2 = imageClip(path); c2.crop = Crop(l: 0, t: 0.25, r: 0, b: 0.25)    // 中央の 16 行
        let p2 = try render(project(w: N, h: N, clips: [c2]))
        for y in 8..<24 { XCTAssertEqual(p2.rgb(10, y), src.rgb(10, y)) }
        XCTAssertEqual(p2.rgb(10, 3), [0, 0, 0])
    }

    // MARK: キーフレーム

    func testKeyframedXMovesLinearlyAtThreeTimes() throws {
        let red = try solidPNG("red.png", r: 255, g: 0, b: 0)
        var c = imageClip(red, start: 0.5, dur: 2); c.scale = 0.2                       // 一辺 20px
        c.keyframes["x"] = [Keyframe(t: 0, v: 0.25), Keyframe(t: 2, v: 0.75)]           // 200×100 の画面で 50px → 150px
        let p = project(w: 200, h: 100, clips: [c])
        for (t, cx) in [(0.5, 50.0), (1.5, 100.0), (2.49, 149.0)] {
            let px = try render(p, t: t)
            XCTAssertEqual(px.rgb(Int(cx), 50), [255, 0, 0], "t=\(t)")
            XCTAssertEqual(px.rgb(Int(cx) - 14, 50), [0, 0, 0], "t=\(t) 左")
            XCTAssertEqual(px.rgb(Int(cx) + 14, 50), [0, 0, 0], "t=\(t) 右")
        }
    }

    func testKeyframedOpacityScaleAndRotation() throws {
        let red = try solidPNG("red.png", r: 255, g: 0, b: 0)
        var c = imageClip(red, dur: 2); c.scale = 0.2
        c.keyframes["opacity"] = [Keyframe(t: 0, v: 0), Keyframe(t: 2, v: 1)]
        let p = project(w: 200, h: 100, clips: [c])
        XCTAssertEqual(try render(p, t: 0).rgb(100, 50), [0, 0, 0])
        let half = try render(p, t: 1).rgb(100, 50)
        XCTAssertEqual(Double(half[0]), 127.5, accuracy: 3)
        XCTAssertEqual(try render(p, t: 1.999).rgb(100, 50)[0], 254, accuracy: 2)
        // 拡大
        var s = imageClip(red, dur: 2); s.scale = 0.1
        s.keyframes["scale"] = [Keyframe(t: 0, v: 0.1), Keyframe(t: 2, v: 0.4)]
        let ps = project(w: 200, h: 100, clips: [s])
        XCTAssertEqual(try render(ps, t: 0).rgb(100 + 15, 50), [0, 0, 0])             // 一辺 10px
        XCTAssertEqual(try render(ps, t: 1.99).rgb(100 + 17, 50), [255, 0, 0])        // 一辺 ≈ 40px
        // 回転 0 → 90 度(正方形なので見た目は同じだが、45 度ではさえぎる範囲が変わる)
        var r = imageClip(red, dur: 2); r.scale = 0.2
        r.keyframes["rotation"] = [Keyframe(t: 0, v: 0), Keyframe(t: 2, v: 90)]
        let pr = project(w: 200, h: 100, clips: [r])
        XCTAssertEqual(try render(pr, t: 0).rgb(100 + 9, 50 + 9), [255, 0, 0])        // 回す前は角まで赤
        XCTAssertEqual(try render(pr, t: 1).rgb(100 + 9, 50 + 9), [0, 0, 0])          // 45 度で角が外へ
    }

    func testKeyframesBeforeAndAfterHoldEndValues() throws {
        let red = try solidPNG("red.png", r: 255, g: 0, b: 0)
        var c = imageClip(red, start: 0, dur: 4); c.scale = 0.2
        c.keyframes["x"] = [Keyframe(t: 1, v: 0.25), Keyframe(t: 2, v: 0.75)]
        let p = project(w: 200, h: 100, clips: [c])
        XCTAssertEqual(try render(p, t: 0.2).rgb(50, 50), [255, 0, 0])      // 最初のキーより前
        XCTAssertEqual(try render(p, t: 3.5).rgb(150, 50), [255, 0, 0])     // 最後のキーより後
    }

    func testBlurRegionPositionIsKeyframed() throws {
        // 縦縞の背景(画像)の上で、ぼかし範囲が左から右へ動く。ぼかされた(= 変わった)場所の重心を見る
        let N = 200
        var d = [UInt8](repeating: 255, count: N * 100 * 4)
        for y in 0..<100 { for x in 0..<N { let on: UInt8 = (x / 4) % 2 == 0 ? 255 : 0; let i = (y * N + x) * 4; d[i] = on; d[i + 1] = on; d[i + 2] = on } }
        let img = d.withUnsafeMutableBytes { raw -> CGImage in
            CGContext(data: raw.baseAddress, width: N, height: 100, bitsPerComponent: 8, bytesPerRow: N * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        }
        let path = try writePNG(img, "stripes.png")
        var bg = imageClip(path, dur: 3); bg.scale = 1
        var blur = Clip(); blur.id = "b"; blur.type = .blur; blur.start = 0; blur.duration = 3
        blur.x = 0.5; blur.y = 0.5; blur.w = 0.2; blur.h = 0.6; blur.strength = 6; blur.shape = "rect"
        blur.keyframes["x"] = [Keyframe(t: 0, v: 0.2), Keyframe(t: 3, v: 0.8)]
        var plain = blur; plain.keyframes = [:]; plain.strength = 0
        func centroid(_ t: Double) throws -> Double {
            let a = try render(project(w: N, h: 100, clips: [bg, blur]), t: t), b = try render(project(w: N, h: 100, clips: [bg, plain]), t: t)
            var sum = 0.0, n = 0.0
            for y in 0..<100 { for x in 0..<N { let diff = abs(a.rgb(x, y)[0] - b.rgb(x, y)[0]); if diff > 20 { sum += Double(x); n += 1 } } }
            return n > 0 ? sum / n : -1
        }
        XCTAssertEqual(try centroid(0), 40, accuracy: 3)
        XCTAssertEqual(try centroid(1.5), 100, accuracy: 3)
        XCTAssertEqual(try centroid(2.99), 160, accuracy: 3)
    }

    // MARK: 文字

    func brightBounds(_ px: Pixels, threshold: Int = 60) -> (minX: Int, maxX: Int, minY: Int, maxY: Int)? {
        var r: (Int, Int, Int, Int)?
        for y in 0..<px.h { for x in 0..<px.w where px.rgb(x, y)[0] + px.rgb(x, y)[1] + px.rgb(x, y)[2] > threshold * 3 {
            if let c = r { r = (min(c.0, x), max(c.1, x), min(c.2, y), max(c.3, y)) } else { r = (x, x, y, y) }
        } }
        return r.map { (minX: $0.0, maxX: $0.1, minY: $0.2, maxY: $0.3) }
    }

    func textClip(_ s: String) -> Clip {
        var c = Clip(); c.id = "t"; c.type = .text; c.start = 0; c.duration = 4; c.text = s; c.fontSize = 40; c.x = 0.5; c.y = 0.5; c.color = "#ffffff"; c.outline = "#ffffff"
        return c
    }

    func testTextRotation90SwapsExtentsAndKeepsCenter() throws {
        var flat = textClip("MMMMMM")
        let a = try XCTUnwrap(brightBounds(render(project(w: 400, h: 300, clips: [flat]))))
        XCTAssertGreaterThan(a.maxX - a.minX, 2 * (a.maxY - a.minY))                 // 横長
        flat.rotation = 90
        let b = try XCTUnwrap(brightBounds(render(project(w: 400, h: 300, clips: [flat]))))
        XCTAssertGreaterThan(b.maxY - b.minY, 2 * (b.maxX - b.minX))                 // 縦長
        XCTAssertEqual(Double(b.minX + b.maxX) / 2, Double(a.minX + a.maxX) / 2, accuracy: 3)   // 中心は動かない
        XCTAssertEqual(Double(b.minY + b.maxY) / 2, Double(a.minY + a.maxY) / 2, accuracy: 3)
        flat.rotation = 180
        let c = try XCTUnwrap(brightBounds(render(project(w: 400, h: 300, clips: [flat]))))
        XCTAssertEqual(c.maxX - c.minX, a.maxX - a.minX, accuracy: 2)
    }

    func testTextFlipMirrorsAndScaleGrows() throws {
        var t = textClip("LLL")
        let base = try render(project(w: 400, h: 300, clips: [t]))
        t.flipH = true
        let fl = try render(project(w: 400, h: 300, clips: [t]))
        let b0 = try XCTUnwrap(brightBounds(base)), b1 = try XCTUnwrap(brightBounds(fl))
        XCTAssertEqual(b0.maxX - b0.minX, b1.maxX - b1.minX, accuracy: 2)
        XCTAssertNotEqual(base.d, fl.d)
        // 鏡像: 左右を入れ替えた画素と、ほぼ同じ(中心が整数画素でないぶん 1 画素ずれることがある)
        var diff = 0
        let w = base.w
        for y in stride(from: 0, to: base.h, by: 2) { for x in 4..<(w - 4) where abs(base.rgb(x, y)[0] - fl.rgb(w - 1 - x, y)[0]) > 100 && abs(base.rgb(x, y)[0] - fl.rgb(w - x, y)[0]) > 100 { diff += 1 } }
        XCTAssertEqual(diff, 0)
        var s = textClip("LLL"); s.scale = 2
        let big = try XCTUnwrap(brightBounds(render(project(w: 400, h: 300, clips: [s]))))
        XCTAssertEqual(Double(big.maxX - big.minX), Double(b0.maxX - b0.minX) * 2, accuracy: 10)
    }

    func testTextCropClipsTheBox() throws {
        var t = textClip("MMMMMM")
        let full = try XCTUnwrap(brightBounds(render(project(w: 400, h: 300, clips: [t]))))
        t.crop = Crop(l: 0, t: 0, r: 0.5, b: 0)                         // 左半分だけ残す
        let half = try XCTUnwrap(brightBounds(render(project(w: 400, h: 300, clips: [t]))))
        XCTAssertEqual(Double(half.maxX - half.minX), Double(full.maxX - full.minX) / 2, accuracy: 12)
        XCTAssertEqual(Double(half.minX + half.maxX) / 2, 200, accuracy: 6)    // 残った部分の中心がアンカーに来る
    }

    func testTextKeyframedPositionAndOpacity() throws {
        var t = textClip("MMM"); t.duration = 2
        t.keyframes["x"] = [Keyframe(t: 0, v: 0.25), Keyframe(t: 2, v: 0.75)]
        let p = project(w: 400, h: 300, clips: [t])
        let c0 = try XCTUnwrap(brightBounds(render(p, t: 0))), c1 = try XCTUnwrap(brightBounds(render(p, t: 1))), c2 = try XCTUnwrap(brightBounds(render(p, t: 1.99)))
        XCTAssertEqual(Double(c0.minX + c0.maxX) / 2, 100, accuracy: 3)
        XCTAssertEqual(Double(c1.minX + c1.maxX) / 2, 200, accuracy: 3)
        XCTAssertEqual(Double(c2.minX + c2.maxX) / 2, 298, accuracy: 4)
        var o = textClip("MMM"); o.duration = 2
        o.keyframes["opacity"] = [Keyframe(t: 0, v: 0), Keyframe(t: 2, v: 1)]
        XCTAssertNil(brightBounds(try render(project(w: 400, h: 300, clips: [o]), t: 0)))
        XCTAssertNotNil(brightBounds(try render(project(w: 400, h: 300, clips: [o]), t: 1.9)))
    }

    func testUntouchedClipsRenderIdenticallyWithAndWithoutEmptyKeyframeTable() throws {
        let red = try solidPNG("red.png", r: 255, g: 0, b: 0)
        var a = imageClip(red); a.scale = 0.3
        var b = a; b.keyframes = ["x": []]
        XCTAssertEqual(try render(project(w: 200, h: 100, clips: [a])).d, try render(project(w: 200, h: 100, clips: [b])).d)
        var ta = textClip("あいう"); ta.outline = "#000000"
        var tb = ta; tb.rotation = 0; tb.flipH = false; tb.crop = Crop()
        XCTAssertEqual(try render(project(w: 400, h: 300, clips: [ta])).d, try render(project(w: 400, h: 300, clips: [tb])).d)
    }

    func testObjectSizeForHandles() throws {
        let N = 32
        let (path, _) = try noisePNG(size: N)
        var c = imageClip(path); c.scale = 0.5
        let r = Renderer(project: project(w: 64, h: 64, clips: [c]), assets: RenderAssets())
        // 64×64 の画面に 32×32 の画像: 全体にフィットすると 64、scale 0.5 で 32
        XCTAssertEqual(try XCTUnwrap(r.objectSize(of: c, at: 0)).width, 32, accuracy: 1e-9)
        c.crop = Crop(l: 0.5, t: 0, r: 0, b: 0)
        XCTAssertEqual(try XCTUnwrap(r.objectSize(of: c, at: 0)).width, 16, accuracy: 1e-9)
        c.keyframes["scale"] = [Keyframe(t: 0, v: 0.5), Keyframe(t: 2, v: 1)]
        XCTAssertEqual(try XCTUnwrap(r.objectSize(of: c, at: 2)).width, 32, accuracy: 1e-9)
        var t = textClip("MMMM")
        let rt = Renderer(project: project(w: 400, h: 300, clips: [t]), assets: RenderAssets())
        let s = try XCTUnwrap(rt.objectSize(of: t, at: 0))
        XCTAssertEqual(s.height, 40 * 1.2, accuracy: 1e-9); XCTAssertGreaterThan(s.width, 60)
        t.text = "A\nBB\nC"
        XCTAssertEqual(try XCTUnwrap(rt.objectSize(of: t, at: 0)).height, 3 * 40 * 1.2, accuracy: 1e-9)
        var a = Clip(); a.type = .audio
        XCTAssertNil(rt.objectSize(of: a, at: 0))
    }
}
