import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import MovieCutCore

/// 第2波バッチC の描画テスト: ルールワイプのマスクの向き・モザイク解除・境界ぼかし・
/// 傾斜・バウンスが、実際のフレームに効くことを画素で確かめる。
final class TransitionPresetRenderTests: XCTestCase {
    struct Pixels {
        let w: Int, h: Int
        var d: [UInt8]
        func rgb(_ x: Int, _ y: Int) -> [Int] { let i = (y * w + x) * 4; return [Int(d[i]), Int(d[i + 1]), Int(d[i + 2])] }
        func white(_ x: Int, _ y: Int) -> Bool { rgb(x, y)[0] > 200 }
        var whiteCount: Int { (0..<(w * h)).filter { d[$0 * 4] > 128 }.count }
    }

    func pixels(_ img: CGImage) -> Pixels {
        var d = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let c = CGContext(data: &d, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return Pixels(w: img.width, h: img.height, d: d)
    }

    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("transition-preset-tests-\(UUID().uuidString)")
    override func setUpWithError() throws { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    let W = 64, H = 36

    func solid(_ name: String, r: UInt8, g: UInt8, b: UInt8, w: Int? = nil, h: Int? = nil) throws -> String {
        let w = w ?? W, h = h ?? H
        let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1))
        c.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return try writePNG(c.makeImage()!, name)
    }

    /// 縦縞(2px ごとの白黒)。
    func stripes(_ name: String) throws -> String {
        let c = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for x in stride(from: 0, to: W, by: 2) {
            c.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            c.fill(CGRect(x: x, y: 0, width: 1, height: H))
        }
        return try writePNG(c.makeImage()!, name)
    }

    func writePNG(_ img: CGImage, _ name: String) throws -> String {
        let url = tmp.appendingPathComponent(name)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, img, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url.path
    }

    func clip(_ path: String, tin: Transition? = nil, tout: Transition? = nil, scale: Double = 1) -> Clip {
        var c = Clip(); c.id = UUID().uuidString; c.type = .image; c.src = path; c.start = 0; c.duration = 4
        c.x = 0.5; c.y = 0.5; c.scale = scale; c.transitionIn = tin; c.transitionOut = tout
        return c
    }

    func project(_ clips: [Clip]) -> Project {
        var p = Project(); p.width = W; p.height = H; p.bg = "#000000"; p.characters = []
        var t = Track(name: "L1"); t.clips = clips; p.tracks = [t]
        return p
    }

    func render(_ p: Project, _ t: Double) throws -> Pixels {
        pixels(try XCTUnwrap(Renderer(project: p, assets: RenderAssets()).renderImage(t: t)))
    }

    // MARK: ルールワイプの向きと進行

    func testRuleHorizontalRevealsFromLeft() throws {
        let white = try solid("w.png", r: 255, g: 255, b: 255)
        var tr = Transition(.ruleHorizontal, duration: 1, ease: .linear)
        tr.params = .object(["softness": .number(0)])
        let p = project([clip(white, tin: tr)])
        let mid = try render(p, 0.5)
        XCTAssertTrue(mid.white(4, 18)); XCTAssertTrue(mid.white(28, 18))
        XCTAssertFalse(mid.white(36, 18)); XCTAssertFalse(mid.white(60, 18))
        XCTAssertEqual(try render(p, 0).whiteCount, 0)
        XCTAssertEqual(try render(p, 1).whiteCount, W * H)
        // 退場は登場と逆順に消える(先に現れた左が最後まで残る)
        let o = project([clip(white, tout: tr)])
        let om = try render(o, 3.5)
        XCTAssertTrue(om.white(4, 18)); XCTAssertFalse(om.white(60, 18))
    }

    func testRuleVerticalRevealsFromTop() throws {
        let white = try solid("w.png", r: 255, g: 255, b: 255)
        var tr = Transition(.ruleVertical, duration: 1, ease: .linear)
        tr.params = .object(["softness": .number(0)])
        let mid = try render(project([clip(white, tin: tr)]), 0.5)
        XCTAssertTrue(mid.white(32, 3)); XCTAssertTrue(mid.white(32, 15))
        XCTAssertFalse(mid.white(32, 21)); XCTAssertFalse(mid.white(32, 33))
    }

    func testRuleCircleAndClockOrientation() throws {
        let white = try solid("w.png", r: 255, g: 255, b: 255)
        var tr = Transition(.ruleCircle, duration: 1, ease: .linear)
        tr.params = .object(["softness": .number(0)])
        let mid = try render(project([clip(white, tin: tr)]), 0.5)
        XCTAssertTrue(mid.white(32, 18))                       // 中心は見える
        XCTAssertFalse(mid.white(1, 1)); XCTAssertFalse(mid.white(62, 34))   // 角はまだ
        var ck = Transition(.ruleClock, duration: 1, ease: .linear)
        ck.params = .object(["softness": .number(0)])
        let q = try render(project([clip(white, tin: ck)]), 0.25)
        XCTAssertTrue(q.white(50, 5))                          // 右上(12時→3時)だけ
        XCTAssertFalse(q.white(14, 5)); XCTAssertFalse(q.white(50, 32)); XCTAssertFalse(q.white(14, 32))
    }

    func testRuleCoverageIsMonotonic() throws {
        let white = try solid("w.png", r: 255, g: 255, b: 255)
        for kind in [TransitionKind.ruleHorizontal, .ruleChecker, .ruleSpiral, .shatter] {
            let p = project([clip(white, tin: Transition(kind, duration: 1, ease: .linear))])
            let counts = try [0.15, 0.4, 0.65, 0.9].map { try render(p, $0).whiteCount }
            for i in 1..<counts.count { XCTAssertGreaterThan(counts[i], counts[i - 1], "\(kind) \(counts)") }
            XCTAssertEqual(try render(p, 1).whiteCount, W * H, "\(kind)")
        }
    }

    func testRuleSoftnessBlursTheBoundary() throws {
        let white = try solid("w.png", r: 255, g: 255, b: 255)
        var soft = Transition(.ruleHorizontal, duration: 1, ease: .linear)
        soft.params = .object(["softness": .number(0.4)])
        let m = try render(project([clip(white, tin: soft)]), 0.5)
        let boundary = m.rgb(32, 18)[0]
        XCTAssertGreaterThan(boundary, 40); XCTAssertLessThan(boundary, 215)   // 境界は中間色
        XCTAssertTrue(m.white(4, 18)); XCTAssertFalse(m.white(60, 18))
    }

    func testCustomRuleImage() throws {
        // 左半分が黒・右半分が白のルール画像: 進行 0.5 では右半分(値 1 はまだ)ではなく…
        // 値 0 の左半分が先に見える
        let c = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        c.fill(CGRect(x: W / 2, y: 0, width: W / 2, height: H))
        let rulePath = try writePNG(c.makeImage()!, "rule.png")
        let white = try solid("w.png", r: 255, g: 255, b: 255)
        var tr = Transition(.ruleCustom, duration: 1, ease: .linear)
        tr.params = .object(["softness": .number(0), "ruleSrc": .string(rulePath)])
        let mid = try render(project([clip(white, tin: tr)]), 0.5)
        XCTAssertTrue(mid.white(4, 18))                        // ルール値 0 の左が先
        XCTAssertFalse(mid.white(60, 18))                      // ルール値 1 の右はまだ
        XCTAssertTrue(try render(project([clip(white, tin: tr)]), 1.0).white(60, 18))   // 終われば全部見える
    }

    // MARK: 演出系

    func testMosaicReleasePixelates() throws {
        // 大きめのキャンバスで(モザイクのブロックは 1920 基準の px なので、小さい画面では効きが弱い)
        let bw = 320, bh = 180
        let c = CGContext(data: nil, width: bw, height: bh, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        c.fill(CGRect(x: 0, y: 0, width: bw, height: bh))
        c.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        for x in stride(from: 0, to: bw, by: 4) { c.fill(CGRect(x: x, y: 0, width: 2, height: bh)) }   // 2px 白・2px 黒の縞
        let s = try writePNG(c.makeImage()!, "s2.png")
        var cl = clip(s, tin: Transition(.mosaicRelease, duration: 1, ease: .linear))
        cl.id = "m"
        var p = Project(); p.width = bw; p.height = bh; p.bg = "#000000"; p.characters = []
        var t = Track(name: "L1"); t.clips = [cl]; p.tracks = [t]
        // 開始直後(モザイク最大): 細い縞が大きなブロックになる(色の切り替わりが減る)。
        // CIPixellate はブロック中心の色で塗るので、中間色にはならず「runs が長くなる」ことで確かめる
        func transitions(_ px: Pixels, y: Int, w: Int) -> Int {
            var n = 0
            for x in 1..<w { if px.rgb(x, y)[0] != px.rgb(x - 1, y)[0] { n += 1 } }
            return n
        }
        let early = try render(p, 0.05)
        XCTAssertLessThan(transitions(early, y: 90, w: bw), 80)
        XCTAssertTrue((0..<bw).contains { early.rgb($0, 90)[0] > 200 })    // 白ブロックも黒ブロックもある
        XCTAssertTrue((0..<bw).contains { early.rgb($0, 90)[0] < 55 })
        // 終われば元の細い縞に戻る
        let done = try render(p, 1.0)
        XCTAssertGreaterThan(transitions(done, y: 90, w: bw), 120)
        // クリップ自身にエフェクトは残らない
        XCTAssertTrue(p.tracks[0].clips[0].effects.isEmpty)
    }

    func testEdgeBlurReleaseKeepsCentreSharp() throws {
        let white = try solid("w.png", r: 255, g: 255, b: 255)
        let p = project([clip(white, tin: Transition(.edgeBlurRelease, duration: 1, ease: .linear), scale: 0.5)])
        let mid = try render(p, 0.5)
        XCTAssertEqual(mid.rgb(32, 18), [255, 255, 255])       // 中心は鮮明なまま
        let edge = mid.rgb(17, 18)[0]                          // 絵の左端の内側: 縁が薄れて暗くなる
        XCTAssertGreaterThan(edge, 5); XCTAssertLessThan(edge, 250)
        XCTAssertEqual(try render(p, 1.0).rgb(17, 18), [255, 255, 255])   // 終われば端まで鮮明
    }

    func testSkewChangesThePicture() throws {
        let white = try solid("w.png", r: 255, g: 255, b: 255, w: 32, h: 18)
        let plain = project([clip(white)])
        let skewed = project([clip(white, tin: Transition(.skewIn, duration: 1, ease: .linear))])
        XCTAssertNotEqual(try render(skewed, 0.5).d, try render(plain, 0.5).d)
        XCTAssertEqual(try render(skewed, 1.0).d, try render(plain, 1.0).d)
    }

    func testBounceEntersFromBelow() throws {
        let white = try solid("w.png", r: 255, g: 255, b: 255)
        let p = project([clip(white, tin: Transition(.bounceIn, duration: 1, ease: .linear))])
        let c0 = try render(p, 0).whiteCount
        let c1 = try render(p, 0.5).whiteCount
        XCTAssertLessThan(c0, c1)
        XCTAssertLessThan(c1, W * H)
        XCTAssertFalse(try render(p, 0).white(32, 2))          // 頭は上が空いている
        XCTAssertEqual(try render(p, 1).whiteCount, W * H)
    }

    func testBubbleFollowsFade() throws {
        // 吹き出し付き文字: フェードの途中では吹き出しの塗りも半分に薄れる
        func bubbleClip(_ tr: Transition?) -> Clip {
            var c = Clip(); c.id = UUID().uuidString; c.type = .text; c.text = "あ"; c.start = 0; c.duration = 4
            c.x = 0.5; c.y = 0.5; c.fontSize = 40; c.bubble = Bubble(); c.transitionIn = tr
            return c
        }
        var p = Project(); p.width = 200; p.height = 100; p.bg = "#000000"; p.characters = []
        var t1 = Track(name: "L1"); t1.clips = [bubbleClip(Transition(.fade, duration: 1, ease: .linear))]; p.tracks = [t1]
        let mid = try render(p, 0.5)
        let fill = mid.rgb(56, 50)[0]                          // 吹き出しの左端の内側(文字から離れた所)
        XCTAssertGreaterThan(fill, 80); XCTAssertLessThan(fill, 175)
        var p2 = Project(); p2.width = 200; p2.height = 100; p2.bg = "#000000"; p2.characters = []
        var t2 = Track(name: "L1"); t2.clips = [bubbleClip(nil)]; p2.tracks = [t2]
        XCTAssertEqual(try render(p2, 0.5).rgb(56, 50), [255, 255, 255])   // トランジションなしでは真っ白
    }
}
