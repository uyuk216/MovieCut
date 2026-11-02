import XCTest
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import MovieCutCore

/// 光学ミスト(ハイライトのにじみ)。画素・ファイル・描画経路・速度。
final class OpticalMistTests: XCTestCase {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mist-tests-\(UUID().uuidString)")
    override func setUpWithError() throws { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    struct Pixels {
        let w: Int, h: Int
        var d: [UInt8]
        func rgb(_ x: Int, _ y: Int) -> [Int] { let i = (y * w + x) * 4; return [Int(d[i]), Int(d[i + 1]), Int(d[i + 2])] }
        func luma(_ x: Int, _ y: Int) -> Double { let c = rgb(x, y); return 0.2126 * Double(c[0]) + 0.7152 * Double(c[1]) + 0.0722 * Double(c[2]) }
    }

    func pixels(_ img: CGImage) -> Pixels {
        var d = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let c = CGContext(data: &d, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return Pixels(w: img.width, h: img.height, d: d)
    }

    /// 200×200。背景 `bg` の中央に 40×40 の `gray` の四角。
    func squarePNG(gray: CGFloat = 1, bg: CGFloat = 0) throws -> String {
        let n = 200
        let c = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(gray: bg, alpha: 1); c.fill(CGRect(x: 0, y: 0, width: n, height: n))
        c.setFillColor(gray: gray, alpha: 1); c.fill(CGRect(x: 80, y: 80, width: 40, height: 40))
        let url = tmp.appendingPathComponent("sq-\(gray)-\(bg).png")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, c.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url.path
    }

    /// 200×200 のキャンバスいっぱいに画像を置く(背景は黒)
    func project(_ path: String, _ effects: [Effect]) -> Project {
        var c = Clip(); c.id = "i"; c.type = .image; c.src = path; c.start = 0; c.duration = 4; c.x = 0.5; c.y = 0.5; c.scale = 1
        c.effects = effects
        var p = Project(); p.width = 200; p.height = 200; p.bg = "#000000"; p.characters = []
        var tr = Track(name: "L1"); tr.clips = [c]; p.tracks = [tr]
        return p
    }

    func render(_ p: Project) throws -> Pixels {
        pixels(try XCTUnwrap(Renderer(project: p, assets: RenderAssets()).renderImage(t: 0.5)))
    }

    /// px の引数は 1920×1080 での大きさ。この 200×200 のキャンバスで `v` 画素にするための値。
    func px(_ v: Double) -> Double { v / (200.0 * 200.0 / (1920.0 * 1080.0)).squareRoot() }

    func mist(_ amount: Double = 0.8, _ threshold: Double = 0.7, radius: Double = 10) -> Effect {
        var e = Effect(.opticalMist)
        e.params = ["amount": amount, "threshold": threshold, "radius": px(radius)]
        return e
    }

    func testGlowSpreadsFromHighlightOnly() throws {
        let path = try squarePNG()
        let base = try render(project(path, []))
        XCTAssertEqual(base.luma(100, 100), 255, accuracy: 2, "前提: 白い四角が中央に出る")
        let m = try render(project(path, [mist()]))
        XCTAssertGreaterThan(m.luma(125, 100), base.luma(125, 100) + 20, "四角の縁の外が明るくなる")
        XCTAssertLessThan(m.luma(10, 10), 3, "遠い所は暗いまま")
        XCTAssertGreaterThan(m.luma(100, 100), 250, "四角の中は白のまま")
    }

    func testAmountZeroAndThresholdOneChangeNothing() throws {
        let path = try squarePNG()
        let base = try render(project(path, []))
        XCTAssertEqual(try render(project(path, [mist(0)])).d, base.d, "量 0 は速い道(画素が同じ)")
        let grey = try squarePNG(gray: 0.9, bg: 0.9)
        let g0 = try render(project(grey, []))
        let g1 = try render(project(grey, [mist(1, 1.0)]))
        for (x, y) in [(10, 10), (100, 100), (125, 100)] { XCTAssertEqual(g1.luma(x, y), g0.luma(x, y), accuracy: 2) }
        // 純関数として: 量 0 は同じ画像を返す
        let ci = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        XCTAssertEqual(OpticalMist.apply(ci, amount: 0, threshold: 0.5, sigma: 4).extent, ci.extent)
    }

    func testDefaultsRangesAndIdentity() {
        let e = Effect(.opticalMist)
        XCTAssertEqual(e.params, ["amount": 0.5, "threshold": 0.7, "radius": 24])
        XCTAssertEqual(EffectKind.opticalMist.label, "光学ミスト")
        XCTAssertEqual(EffectKind.opticalMist.params.map(\.key), ["amount", "threshold", "radius"])
        var z = Effect(.opticalMist); z.params["amount"] = 0
        var c = Clip(); c.type = .image; c.src = "/a.png"; c.effects = [z]
        XCTAssertTrue(EffectPipeline.resolve(c, atClipTime: 0).isEmpty)
        c.effects = [Effect(.opticalMist)]
        XCTAssertEqual(EffectPipeline.resolve(c, atClipTime: 0).count, 1)
    }

    func testRoundTripAndDefaultOmission() throws {
        var c = Clip(); c.id = "m"; c.type = .image; c.src = "/a.png"; c.effects = [Effect(.opticalMist), Effect(kind: "opticalMist")]
        var p = Project(); p.tracks = [Track(name: "t")]; p.tracks[0].clips = [c]
        let data = try p.encoded()
        let p2 = try Project.decode(from: data)
        XCTAssertEqual(p, p2); XCTAssertEqual(try p2.encoded(), data)
        XCTAssertEqual(p2.tracks[0].clips[0].effects[0].known, .opticalMist)
        let bare = String(decoding: try JSONEncoder().encode(Effect(kind: "opticalMist")), as: UTF8.self)
        XCTAssertFalse(bare.contains("params")); XCTAssertFalse(bare.contains("enabled"))
        var plain = Clip(); plain.type = .image; plain.src = "/a.png"
        var q = Project(); q.tracks = [Track(name: "t")]; q.tracks[0].clips = [plain]
        XCTAssertFalse(String(decoding: try q.encoded(), as: UTF8.self).contains("opticalMist"))
        for n in ["rich", "electron-made", "keyframes", "transitions", "effects"] {
            let url = try XCTUnwrap(Bundle.module.url(forResource: n, withExtension: "ymproj", subdirectory: "Fixtures"))
            let raw = try Data(contentsOf: url)
            let f = try Project.decode(from: raw)
            XCTAssertFalse(String(decoding: try f.encoded(), as: UTF8.self).contains("opticalMist"), n)
        }
    }

    func testRendererMatchesEffectPipeline() throws {
        let path = try squarePNG()
        let rendered = try render(project(path, [mist()]))
        let plain = try XCTUnwrap(Renderer(project: project(path, []), assets: RenderAssets()).renderImage(t: 0.5))
        let ci = CIImage(cgImage: plain)
        let scale = (Double(plain.width * plain.height) / (1920.0 * 1080.0)).squareRoot()
        var c = Clip(); c.effects = [mist()]
        let fxs = EffectPipeline.resolve(c, atClipTime: 0.5)
        XCTAssertEqual(fxs.count, 1)
        let out = EffectPipeline.apply(ci, effects: fxs, bounds: ci.extent, scale: scale)
        let direct = pixels(try XCTUnwrap(EffectPipeline.makeImage(out, from: ci.extent)))
        var worst = 0
        for y in stride(from: 0, to: 200, by: 3) { for x in stride(from: 0, to: 200, by: 3) {
            worst = max(worst, zip(rendered.rgb(x, y), direct.rgb(x, y)).map { abs($0 - $1) }.max()!)
        } }
        XCTAssertLessThanOrEqual(worst, 4, "Renderer(プレビュー・書き出し共通)と EffectPipeline は同じ見た目")
    }

    func testPerformanceAt1080p() throws {
        let w = 1920, h = 1080
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(gray: 0.2, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(gray: 1, alpha: 1); ctx.fill(CGRect(x: 800, y: 400, width: 300, height: 200))
        let base = CIImage(cgImage: ctx.makeImage()!)
        var sink: UInt8 = 0
        func run(_ n: Int, _ on: Bool) -> Double {
            let t0 = CFAbsoluteTimeGetCurrent()
            for i in 0..<n {
                let img = on ? OpticalMist.apply(base, amount: 0.5 + Double(i) * 0.01, threshold: 0.7, sigma: 24) : base
                // 画素を読み出して、GPU の処理が終わるまで待つ(描画した結果を使う = 書き出しと同じ)
                if let cg = EffectPipeline.makeImage(img, from: base.extent) { sink = pixels(cg).d[0] }
            }
            return (CFAbsoluteTimeGetCurrent() - t0) * 1000 / Double(n)
        }
        _ = run(2, true)
        let off = run(10, false), on = run(10, true)
        print("[OpticalMist] 1920x1080: effect on \(String(format: "%.1f", on)) ms/frame, off \(String(format: "%.1f", off)) ms/frame (single measurement)")
        _ = sink
        XCTAssertLessThan(on, 2000, "目安(厳しい閾値ではない)")
    }
}
