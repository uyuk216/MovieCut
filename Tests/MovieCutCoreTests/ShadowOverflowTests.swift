import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import MovieCutCore

/// 影・縁のキャンバス外はみ出し(#27): キャンバスの外にある部分の影・縁が、キャンバスの中へ届くこと。
/// 作業範囲(Renderer.effectWorkRect)の幾何と、画素の両方で確かめる。
/// 対象エフェクトを使わない描画・キャンバス内のクリップの結果は変えない(既存テストと画素一致テストで担保)。
final class ShadowOverflowTests: XCTestCase {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("shadow-overflow-\(UUID().uuidString)")
    override func setUpWithError() throws { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    func pixels(_ img: CGImage) -> [UInt8] {
        var d = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let c = CGContext(data: &d, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4, space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return d
    }
    func rgb(_ d: [UInt8], _ x: Int, _ y: Int, w: Int) -> [Int] { let i = (y * w + x) * 4; return [Int(d[i]), Int(d[i + 1]), Int(d[i + 2])] }

    func solidPNG(r: Double, g: Double, b: Double, size: Int = 100, name: String) throws -> String {
        let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: 1))
        c.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let url = tmp.appendingPathComponent(name)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, c.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url.path
    }

    /// canvas × canvas のキャンバスに、表示サイズ disp の画像を中心 (cx, cy)(キャンバス比)へ置く。
    func project(_ path: String, effects: [Effect], cx: Double, cy: Double = 0.5, disp: Double, canvas: Int = 200, bg: String = "#ff0000") -> Project {
        var c = Clip(); c.id = "i"; c.type = .image; c.src = path; c.start = 0; c.duration = 4
        c.x = cx; c.y = cy
        // 素材 100×100 を disp px で表示する: fit = (canvas/100) * scale、表示 = 100 * fit = canvas * scale
        c.scale = disp / Double(canvas)
        c.effects = effects
        var p = Project(); p.width = canvas; p.height = canvas; p.bg = bg; p.characters = []
        var tr = Track(name: "L1"); tr.clips = [c]; p.tracks = [tr]
        return p
    }
    func render(_ p: Project) throws -> [UInt8] { pixels(try XCTUnwrap(Renderer(project: p, assets: RenderAssets()).renderImage(t: 0.5))) }

    /// px の引数は 1920×1080 での大きさ。canvas×canvas のキャンバスで v 画素にするための値。
    func px(_ v: Double, canvas: Int = 200) -> Double { v / (Double(canvas) * Double(canvas) / (1920.0 * 1080.0)).squareRoot() }

    func shadowFX(dx: Double, dy: Double = 0, blur: Double = 0, canvas: Int = 200) -> Effect {
        var e = Effect(.dropShadow)
        e.params["dx"] = px(dx, canvas: canvas); e.params["dy"] = px(dy, canvas: canvas)
        e.params["blur"] = px(blur, canvas: canvas); e.params["opacity"] = 0.6
        e.color = "#000000"
        return e
    }

    // MARK: 作業範囲の幾何

    func testWorkRectGeometry() {
        let canvas = CGRect(x: 0, y: 0, width: 200, height: 200)
        // キャンバス内のクリップ: 従来どおり 枠+余白(キャンバスで切れる範囲は同じ)
        let inside = Renderer.effectWorkRect(bounds: CGRect(x: 50, y: 50, width: 100, height: 100), margin: 10, canvas: canvas)
        XCTAssertEqual(inside, CGRect(x: 40, y: 40, width: 120, height: 120))
        // 端のクリップ: 余白がキャンバスの外へ出る分も作業範囲に含む(影の落下先ではなく、影の発生源を確保するため)
        let edge = Renderer.effectWorkRect(bounds: CGRect(x: 150, y: 50, width: 100, height: 100), margin: 10, canvas: canvas)
        XCTAssertEqual(edge, CGRect(x: 140, y: 40, width: 70, height: 120))
        // 全体がキャンバスの外でも、余白の届く範囲にあれば発生源を含む(余白より遠い発生源は結果に届かないので切れる)
        let off = Renderer.effectWorkRect(bounds: CGRect(x: -110, y: 50, width: 100, height: 100), margin: 30, canvas: canvas)
        XCTAssertEqual(off.minX, -30); XCTAssertEqual(off.maxX, 20)
        // 余白より遠くにあるクリップは作業範囲が空(何も描かない)
        let far = Renderer.effectWorkRect(bounds: CGRect(x: -500, y: 50, width: 100, height: 100), margin: 30, canvas: canvas)
        XCTAssertTrue(far.isNull)
        // 全画面(bounds = キャンバス): はみ出していないので従来どおりキャンバスで切れる(ぼかしの縁の見た目を変えない)
        let full = Renderer.effectWorkRect(bounds: canvas, margin: 42, canvas: canvas)
        XCTAssertEqual(full, canvas)
        // 一部だけはみ出すクリップは、その辺だけ広がる(上にはみ出し → 上だけ -余白、他はキャンバスまで)
        let top = Renderer.effectWorkRect(bounds: CGRect(x: 50, y: -30, width: 100, height: 100), margin: 10, canvas: canvas)
        XCTAssertEqual(top, CGRect(x: 40, y: -10, width: 120, height: 90))
        // 余白 0 ならキャンバスとの交わりそのもの
        let zero = Renderer.effectWorkRect(bounds: CGRect(x: -50, y: 50, width: 100, height: 100), margin: 0, canvas: canvas)
        XCTAssertEqual(zero, CGRect(x: 0, y: 50, width: 50, height: 100))
    }

    // MARK: 画素: 影

    func testShadowFromFullyOffCanvasClipReachesCanvas() throws {
        // 白い 100×100 の画像を、中心 x=-60px(全体がキャンバスの左外: -110..-10)に置く。
        // 影は dx=+28px なので -82..18 に落ち、キャンバス内の 0..18 は影だけが見えるはず。
        let path = try solidPNG(r: 1, g: 1, b: 1, name: "white.png")
        let p = project(path, effects: [shadowFX(dx: 28)], cx: -60.0 / 200, disp: 100)
        let out = try render(p)
        // 影の帯(5, 100): 黒 60% が赤い背景の上 → 赤が 0.4 倍 ≈ 102、緑・青は 0
        let s = rgb(out, 5, 100, w: 200)
        XCTAssertEqual(Double(s[0]), 255 * 0.4, accuracy: 12, "影が見える: \(s)")
        XCTAssertLessThan(s[1], 12); XCTAssertLessThan(s[2], 12)
        // 影の届かない所(30, 100)は背景のまま
        XCTAssertEqual(rgb(out, 30, 100, w: 200), [255, 0, 0])
        // 対照: エフェクトなしでは全面背景だけ
        let plain = try render(project(path, effects: [], cx: -60.0 / 200, disp: 100))
        XCTAssertEqual(rgb(plain, 5, 100, w: 200), [255, 0, 0])
        print("OVERFLOW shadow at (5,100) = \(s)")
    }

    func testShadowFromPartiallyOffCanvasClip() throws {
        // 半分だけキャンバスの外(中心 x=0: -50..50)。影 dx=+28 → 影は -22..78。
        // キャンバス内の影の見え方は、全体が内側にあるときの影と同じ濃さになること
        let path = try solidPNG(r: 1, g: 1, b: 1, name: "white2.png")
        let half = try render(project(path, effects: [shadowFX(dx: 28)], cx: 0, disp: 100))
        // (60, 100): 本体の右端(50)より外で、影だけの所。影の発生源(32, 100)はキャンバス内
        let a = rgb(half, 60, 100, w: 200)
        XCTAssertEqual(Double(a[0]), 255 * 0.4, accuracy: 12, "\(a)")
        // (10, 100) は本体(白)の上ではなく本体そのもの
        XCTAssertEqual(rgb(half, 10, 100, w: 200), [255, 255, 255])
    }

    func testOutlineFromOffCanvasClipReachesCanvas() throws {
        // 400×400 キャンバス。赤い画像を中心 x=-52px(-102..-2、全体が外)に置き、緑の縁取り 8px。
        // 縁は -110..6 に広がり、キャンバス内の 0..6 に緑の帯が出るはず。
        let canvas = 400
        let path = try solidPNG(r: 1, g: 0, b: 0, name: "red.png")
        var e = Effect(.outline)
        e.params["width"] = px(8, canvas: canvas); e.color = "#00ff00"
        let p = project(path, effects: [e], cx: -52.0 / 400, disp: 100, canvas: canvas, bg: "#000000")
        let out = try render(p)
        let ring = rgb(out, 3, 200, w: 400)
        XCTAssertGreaterThan(ring[1], 200, "縁取りが見える: \(ring)")
        XCTAssertLessThan(ring[0], 60)
        // 縁の届かない所は背景のまま
        XCTAssertEqual(rgb(out, 20, 200, w: 400), [0, 0, 0])
        print("OVERFLOW outline at (3,200) = \(ring)")
    }

    func testGlowFromOffCanvasClipReachesCanvas() throws {
        // グローも同じ経路: 全体が外の白い画像の光がキャンバスへにじむ
        let path = try solidPNG(r: 1, g: 1, b: 1, name: "white3.png")
        var e = Effect(.glow)
        e.params["radius"] = px(20); e.params["intensity"] = 1
        let p = project(path, effects: [e], cx: -60.0 / 200, disp: 100, bg: "#000000")
        let out = try render(p)
        let g = rgb(out, 0, 100, w: 200)
        XCTAssertGreaterThan(g[0], 8, "グローのにじみが見える: \(g)")
        print("OVERFLOW glow at (0,100) = \(g)")
    }

    // MARK: 変えないこと

    func testOnCanvasEffectedClipPixelsAreStable() throws {
        // 全体がキャンバス内のクリップ+影: 影の位置と濃さは従来どおり
        let path = try solidPNG(r: 1, g: 1, b: 1, name: "white4.png")
        let p = project(path, effects: [shadowFX(dx: 28)], cx: 0.5, disp: 100)
        let out = try render(p)
        // 本体 50..150。影は 78..178 のうち本体の外(155, 100)に黒 60%
        let s = rgb(out, 155, 100, w: 200)
        XCTAssertEqual(Double(s[0]), 255 * 0.4, accuracy: 12, "\(s)")
        XCTAssertEqual(rgb(out, 100, 100, w: 200), [255, 255, 255], "本体は白")
        XCTAssertEqual(rgb(out, 190, 100, w: 200), [255, 0, 0], "影の外は背景")
    }

    func testFarOffCanvasClipDrawsNothing() throws {
        // 余白よりずっと遠くのクリップは、影も含めて何も描かない(従来どおり全面背景)
        let path = try solidPNG(r: 1, g: 1, b: 1, name: "white5.png")
        let p = project(path, effects: [shadowFX(dx: 28)], cx: -3, disp: 100)
        let out = try render(p)
        for (x, y) in [(0, 0), (100, 100), (199, 199), (5, 100)] {
            XCTAssertEqual(rgb(out, x, y, w: 200), [255, 0, 0], "(\(x),\(y))")
        }
    }
}
