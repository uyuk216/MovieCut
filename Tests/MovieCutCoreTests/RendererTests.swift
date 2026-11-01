import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import MovieCutCore

final class RendererTests: XCTestCase {
    // MARK: ヘルパー

    struct Pixels {
        let w: Int, h: Int
        var d: [UInt8]
        func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let i = (y * w + x) * 4
            return (Int(d[i]), Int(d[i + 1]), Int(d[i + 2]))
        }
        func lum(_ x: Int, _ y: Int) -> Int { let c = rgb(x, y); return (c.0 + c.1 + c.2) / 3 }
    }

    func pixels(_ img: CGImage) -> Pixels {
        var d = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let c = CGContext(data: &d, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return Pixels(w: img.width, h: img.height, d: d)
    }

    func render(_ p: Project, t: Double = 0.5, assets: RenderAssets = RenderAssets()) throws -> Pixels {
        let img = try XCTUnwrap(Renderer(project: p, assets: assets).renderImage(t: t))
        return pixels(img)
    }

    func project(w: Int = 400, h: Int = 200, bg: String = "#000000", clips: [Clip], characters: [Character]? = nil) -> Project {
        var p = Project()
        p.width = w; p.height = h; p.bg = bg
        var tr = Track(name: "L1"); tr.clips = clips
        p.tracks = [tr]
        if let c = characters { p.characters = c } else { p.characters = [] }
        return p
    }

    func textClip(_ s: String, size: Double = 60, x: Double = 0.5, y: Double = 0.5) -> Clip {
        var c = Clip(); c.type = .text; c.start = 0; c.duration = 2; c.text = s; c.fontSize = size; c.x = x; c.y = y
        return c
    }

    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("renderer-tests-\(UUID().uuidString)")
    override func setUpWithError() throws { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func writePNG(_ img: CGImage, _ name: String) throws -> String {
        let url = tmp.appendingPathComponent(name)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, img, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url.path
    }

    /// 単色の PNG
    func solidPNG(_ name: String, r: UInt8, g: UInt8, b: UInt8, size: Int = 8) throws -> String {
        let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1))
        c.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return try writePNG(c.makeImage()!, name)
    }

    /// 市松模様(16x9 セル)。キャンバスいっぱいに広がる。
    func checkerPNG(_ name: String) throws -> String {
        let cw = 16, ch = 9
        let c = CGContext(data: nil, width: cw, height: ch, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for y in 0..<ch { for x in 0..<cw {
            c.setFillColor(CGColor(gray: (x + y) % 2 == 0 ? 1 : 0, alpha: 1))
            c.fill(CGRect(x: x, y: y, width: 1, height: 1))
        } }
        return try writePNG(c.makeImage()!, name)
    }

    /// 無音 0.5 秒のあとに 440Hz の音を 0.5 秒(16bit mono WAV)
    func writeToneWAV(_ name: String) throws -> String {
        let sr = 44100
        var samples = [Int16]()
        for i in 0..<sr { samples.append(i < sr / 2 ? 0 : Int16(12000 * sin(2 * Double.pi * 440 * Double(i) / Double(sr)))) }
        var data = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; data.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; data.append(Data(bytes: &x, count: 2)) }
        data.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + samples.count * 2)); data.append("WAVEfmt ".data(using: .ascii)!)
        u32(16); u16(1); u16(1); u32(UInt32(sr)); u32(UInt32(sr * 2)); u16(2); u16(16)
        data.append("data".data(using: .ascii)!); u32(UInt32(samples.count * 2))
        for s in samples { u16(UInt16(bitPattern: s)) }
        let url = tmp.appendingPathComponent(name)
        try data.write(to: url)
        return url.path
    }

    // MARK: テスト

    func testHexColor() {
        let c = parseHexColor("#00b140")!.components!
        XCTAssertEqual(Double(c[0]), 0, accuracy: 0.001)
        XCTAssertEqual(Double(c[1]), 177.0 / 255, accuracy: 0.001)
        XCTAssertEqual(Double(c[2]), 64.0 / 255, accuracy: 0.001)
        let s = parseHexColor("#f80")!.components!
        XCTAssertEqual(Double(s[0]), 1, accuracy: 0.001)
        XCTAssertEqual(Double(s[1]), 136.0 / 255, accuracy: 0.001)
        XCTAssertNil(parseHexColor("zzz"))
    }

    func testBackgroundColor() throws {
        let px = try render(project(bg: "#00b140", clips: []))
        XCTAssertEqual(px.w, 400); XCTAssertEqual(px.h, 200)
        for (x, y) in [(0, 0), (399, 199), (200, 100)] {
            let c = px.rgb(x, y)
            XCTAssertEqual(c.0, 0); XCTAssertEqual(c.1, 177); XCTAssertEqual(c.2, 64)
        }
    }

    func testTextDrawsInExpectedAreaOnly() throws {
        let px = try render(project(clips: [textClip("テスト", size: 60)]))
        var inside = 0, far = 0
        for y in 0..<px.h { for x in 0..<px.w where px.lum(x, y) > 20 {
            // 中央 ±(縁含む 3文字ぶん) の外側は何も描かれない
            if abs(x - 200) < 130 && abs(y - 100) < 60 { inside += 1 } else { far += 1 }
        } }
        XCTAssertGreaterThan(inside, 500)
        XCTAssertEqual(far, 0)
        XCTAssertGreaterThan(px.lum(200, 100) + px.lum(190, 95) + px.lum(210, 105), 0)
    }

    func testHiddenTrackSkipped() throws {
        var p = project(clips: [textClip("テスト")])
        p.tracks[0].hidden = true
        let px = try render(p)
        for y in stride(from: 0, to: px.h, by: 3) { for x in stride(from: 0, to: px.w, by: 3) { XCTAssertEqual(px.lum(x, y), 0) } }
    }

    func testClipOutsideTimeRangeNotDrawn() throws {
        var c = textClip("テスト"); c.start = 1; c.duration = 1
        let p = project(clips: [c])
        XCTAssertEqual(try render(p, t: 0.5).d.filter { $0 > 0 }.count, 400 * 200)  // alpha(255)のみ
        XCTAssertGreaterThan(try render(p, t: 1.5).d.filter { $0 > 0 }.count, 400 * 200)
    }

    func testBlurRegionRect() throws {
        let img = try checkerPNG("checker.png")
        var base = Clip(); base.type = .image; base.src = img; base.start = 0; base.duration = 2
        let plain = project(clips: [base])
        var b = Clip(); b.type = .blur; b.start = 0; b.duration = 2; b.x = 0.5; b.y = 0.5; b.w = 0.4; b.h = 0.4; b.strength = 8; b.shape = "rect"
        let blurred = project(clips: [base, b])
        let a = try render(plain), c = try render(blurred)
        // 矩形: x 120..280, y 60..140
        var insideDiff = 0, outsideDiff = 0
        for y in 0..<a.h { for x in 0..<a.w {
            let same = a.rgb(x, y) == c.rgb(x, y)
            if x >= 120 && x < 280 && y >= 60 && y < 140 { if !same { insideDiff += 1 } } else if !same { outsideDiff += 1 }
        } }
        XCTAssertGreaterThan(insideDiff, 2000)
        XCTAssertEqual(outsideDiff, 0)
    }

    func testBlurRegionEllipseCornersUnchanged() throws {
        let img = try checkerPNG("checker.png")
        var base = Clip(); base.type = .image; base.src = img; base.start = 0; base.duration = 2
        var b = Clip(); b.type = .blur; b.start = 0; b.duration = 2; b.x = 0.5; b.y = 0.5; b.w = 0.5; b.h = 0.6; b.strength = 8; b.shape = "ellipse"
        let a = try render(project(clips: [base])), c = try render(project(clips: [base, b]))
        // 楕円の外接矩形 x 100..300, y 40..160 の四隅(楕円の外側)
        for (x0, y0) in [(100, 40), (270, 40), (100, 130), (270, 130)] {
            for y in y0..<(y0 + 25) { for x in x0..<(x0 + 25) {
                let dx = (Double(x) + 0.5 - 200) / 100, dy = (Double(y) + 0.5 - 100) / 60
                if dx * dx + dy * dy > 1.15 { XCTAssertEqual(a.rgb(x, y) == c.rgb(x, y), true, "(\(x),\(y))") }
            } }
        }
        // 中心付近は変わっている
        var diff = 0
        for y in 80..<120 { for x in 170..<230 where a.rgb(x, y) != c.rgb(x, y) { diff += 1 } }
        XCTAssertGreaterThan(diff, 200)
    }

    func testClipBlurReducesSharpness() throws {
        func maxStep(_ px: Pixels) -> Int {
            var m = 0
            for y in 0..<px.h { for x in 1..<px.w { m = max(m, abs(px.lum(x, y) - px.lum(x - 1, y))) } }
            return m
        }
        var t = textClip("テスト", size: 80); t.color = "#ffffff"; t.outline = "#ffffff"
        var tb = t; tb.blur = 6
        let sharp = try render(project(clips: [t])), soft = try render(project(clips: [tb]))
        XCTAssertGreaterThan(maxStep(sharp), 150)
        XCTAssertLessThan(maxStep(soft), maxStep(sharp) / 2)
        // ぼかしでも中心は描かれている
        XCTAssertGreaterThan(soft.d.enumerated().filter { $0.offset % 4 == 0 && $0.element > 20 }.count, 300)
    }

    func testStandingImageSwitchesWithVoice() throws {
        let closed = try solidPNG("closed.png", r: 255, g: 0, b: 0)
        let open = try solidPNG("open.png", r: 0, g: 0, b: 255)
        let wav = try writeToneWAV("tone.wav")
        var ch = Character(); ch.id = "c1"; ch.name = "A"; ch.imgClosed = closed; ch.imgOpen = open
        ch.x = 0.5; ch.y = 0.5; ch.scale = 1; ch.flip = false; ch.alwaysShow = false
        var v = Clip(); v.type = .voice; v.start = 0; v.duration = 1; v.charId = "c1"; v.src = wav; v.text = "あ"; v.subtitle = false
        let p = project(clips: [v], characters: [ch])
        let assets = RenderAssets()
        let env = try XCTUnwrap(assets.mouthEnvelope(for: wav))
        XCTAssertEqual(env.count, 60, accuracy: 1)
        let quiet = try render(p, t: 0.25, assets: assets).rgb(200, 100)
        let loud = try render(p, t: 0.75, assets: assets).rgb(200, 100)
        XCTAssertGreaterThan(quiet.0, 200); XCTAssertLessThan(quiet.2, 50)   // 口閉じ = 赤
        XCTAssertGreaterThan(loud.2, 200); XCTAssertLessThan(loud.0, 50)     // 口開き = 青
        // しゃべっていない時刻(クリップ外)と alwaysShow=false では描かない
        XCTAssertEqual(try render(p, t: 1.5, assets: assets).rgb(200, 100).0, 0)
    }

    func testBounceOffsetFollowsVoiceLevel() throws {
        // バウンス: 無音の間は動かず、音が大きい間は画面の高さの 1.2% まで上へ揺れる。バウンスなしは音量に関係なく同じ位置
        let closed = try solidPNG("bounce.png", r: 255, g: 0, b: 0)
        let wav = try writeToneWAV("bouncetone.wav")
        func make(bounce: Bool?) -> Project {
            var ch = Character(); ch.id = "cb"; ch.name = "B"; ch.imgClosed = closed
            ch.x = 0.5; ch.y = 0.5; ch.scale = 1; ch.flip = false; ch.alwaysShow = false; ch.bounce = bounce
            var v = Clip(); v.type = .voice; v.start = 0; v.duration = 1; v.charId = "cb"; v.src = wav; v.text = "あ"; v.subtitle = false
            return project(w: 400, h: 400, clips: [v], characters: [ch])
        }
        // 立ち絵の上端(赤いピクセルが最初に現れる行)
        func topRow(_ px: Pixels) -> Int? { (0..<px.h).first { y in (0..<px.w).contains { x in px.rgb(x, y).0 > 200 } } }
        let assets = RenderAssets()
        let quiet = try XCTUnwrap(topRow(try render(make(bounce: true), t: 0.25, assets: assets)))
        let loud = try XCTUnwrap(topRow(try render(make(bounce: true), t: 0.75, assets: assets)))
        let lift = quiet - loud
        XCTAssertGreaterThanOrEqual(lift, 4, "音が大きい間は上へ揺れる")
        XCTAssertLessThanOrEqual(Double(lift), Bounce.maxOffset * 400 + 1, "上限は画面高さの 1.2%")
        // バウンスなしは無音・大音量で同じ位置
        let plainQuiet = try XCTUnwrap(topRow(try render(make(bounce: nil), t: 0.25, assets: assets)))
        let plainLoud = try XCTUnwrap(topRow(try render(make(bounce: nil), t: 0.75, assets: assets)))
        XCTAssertEqual(plainQuiet, plainLoud)
        XCTAssertEqual(plainQuiet, quiet, "無音のときはバウンスの有無で位置が変わらない")
    }

    func testExpressionTagAndBlinkChangeStandingImage() throws {
        // 表情タグ [笑顔] はその行の間だけ表情画像に切り替わり、字幕からはタグが消える
        let closed = try solidPNG("eclosed.png", r: 255, g: 0, b: 0)
        let smile = try solidPNG("esmile.png", r: 0, g: 255, b: 0)
        let blink = try solidPNG("eblink.png", r: 255, g: 255, b: 0)
        let wav = try writeToneWAV("etone.wav")
        var ch = Character(); ch.id = "c2"; ch.name = "B"; ch.imgClosed = closed; ch.imgBlink = blink
        ch.expressions = ["笑顔": smile]
        ch.x = 0.5; ch.y = 0.5; ch.scale = 1; ch.flip = false; ch.alwaysShow = false
        var v = Clip(); v.type = .voice; v.start = 0; v.duration = 1; v.charId = "c2"; v.src = wav
        v.text = "[笑顔]あ"; v.subtitle = false
        let p = project(clips: [v], characters: [ch])
        let assets = RenderAssets()
        // 0.25 秒: 口閉じ。タグの行なので笑顔画像(緑)
        let quiet = try render(p, t: 0.25, assets: assets).rgb(200, 100)
        XCTAssertGreaterThan(quiet.1, 200); XCTAssertLessThan(quiet.0, 50)
        // 未知のタグは通常画像(赤)
        var u = v; u.text = "[未知]あ"
        let unk = try render(project(clips: [u], characters: [ch]), t: 0.25, assets: assets).rgb(200, 100)
        XCTAssertGreaterThan(unk.0, 200); XCTAssertLessThan(unk.1, 50)
        // セリフの無いキャラの瞬き(開始から最初の瞬きの途中)は黄色
        var idle = Character(); idle.id = "idle"; idle.imgClosed = closed; idle.imgBlink = blink; idle.x = 0.5; idle.y = 0.5; idle.scale = 1; idle.flip = false
        let idleStart = Blink.starts(seed: "idle", until: 10)[0]
        let eyes = try render(project(clips: [], characters: [idle]), t: idleStart + 0.05, assets: assets).rgb(200, 100)
        XCTAssertGreaterThan(eyes.0, 200); XCTAssertGreaterThan(eyes.1, 200); XCTAssertLessThan(eyes.2, 50)
    }

    func testSubtitleDrawnAtBottom() throws {
        var ch = Character(); ch.id = "c1"; ch.color = "#ff0000"; ch.alwaysShow = false
        var v = Clip(); v.type = .voice; v.start = 0; v.duration = 1; v.charId = "c1"; v.text = "あいう"; v.subtitle = true; v.fontSize = 30
        let px = try render(project(clips: [v], characters: [ch]), t: 0.5)
        var lowerHits = 0, upperHits = 0
        for y in 0..<px.h { for x in 0..<px.w where px.lum(x, y) > 20 { if y > 150 { lowerHits += 1 } else { upperHits += 1 } } }
        XCTAssertGreaterThan(lowerHits, 100)
        XCTAssertEqual(upperHits, 0)
    }

    func testMissingFilesAndUnknownTypesAreTolerated() throws {
        var img = Clip(); img.type = .image; img.src = "/nonexistent/none.png"; img.start = 0; img.duration = 2
        var vid = Clip(); vid.type = .video; vid.src = "/nonexistent/none.mp4"; vid.start = 0; vid.duration = 2
        var weird = Clip(); weird.type = ClipType(rawValue: "hologram"); weird.start = 0; weird.duration = 2
        var voice = Clip(); voice.type = .voice; voice.charId = "zzz"; voice.src = "/nonexistent/none.wav"; voice.start = 0; voice.duration = 2; voice.text = "x"
        var blurImg = img; blurImg.blur = 10
        let px = try render(project(bg: "#102030", clips: [img, vid, weird, blurImg, voice]))
        XCTAssertEqual(px.rgb(10, 10).0, 0x10)
        XCTAssertEqual(px.rgb(10, 10).2, 0x30)
    }

    func testRendersIntoPixelBufferStyleContext() throws {
        // 書き出しの CVPixelBuffer と同じ BGRA 並びの CGContext へ直接描ける
        let p = project(bg: "#ff0000", clips: [])
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info))
        Renderer(project: p, assets: RenderAssets()).render(t: 0, into: ctx)
        let d = ctx.data!.assumingMemoryBound(to: UInt8.self)
        XCTAssertEqual(d[2], 255); XCTAssertEqual(d[1], 0)  // BGRA の R
    }
}
