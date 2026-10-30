import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import MovieCutCore

/// クロマキーと LUT(.cube): パーサー(壊れた入力を含む)・描画(画素を測る)・ファイル・編集。
final class ChromaLUTTests: XCTestCase {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("chroma-lut-\(UUID().uuidString)")
    override func setUpWithError() throws { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    func pixels(_ img: CGImage) -> [UInt8] {
        var d = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let c = CGContext(data: &d, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4, space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return d
    }
    func rgb(_ d: [UInt8], _ x: Int, _ y: Int, w: Int = 200) -> [Int] { let i = (y * w + x) * 4; return [Int(d[i]), Int(d[i + 1]), Int(d[i + 2])] }

    func writePNG(_ img: CGImage, _ name: String) throws -> String {
        let url = tmp.appendingPathComponent(name)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, img, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url.path
    }

    /// 100×100: 純粋な緑(0,255,0)の地に、青い四角(30..70)と、緑かぶりした肌色の四角。
    func greenScreenPNG() throws -> String {
        let c = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        c.setFillColor(CGColor(srgbRed: 30.0 / 255, green: 60.0 / 255, blue: 220.0 / 255, alpha: 1)); c.fill(CGRect(x: 30, y: 30, width: 40, height: 40))
        return try writePNG(c.makeImage()!, "green.png")
    }

    func gradientPNG() throws -> String {
        let size = 100
        let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for y in 0..<size { for x in 0..<size {
            c.setFillColor(CGColor(srgbRed: CGFloat(x) / CGFloat(size) * 0.8 + 0.1, green: CGFloat(y) / CGFloat(size) * 0.6 + 0.1, blue: 0.7 - CGFloat(x) / CGFloat(size) * 0.5, alpha: 1))
            c.fill(CGRect(x: x, y: y, width: 1, height: 1))
        } }
        return try writePNG(c.makeImage()!, "gradient.png")
    }

    func project(_ path: String, effects: [Effect], bg: String = "#ff0000") -> Project {
        var c = Clip(); c.id = "i"; c.type = .image; c.src = path; c.start = 0; c.duration = 4; c.x = 0.5; c.y = 0.5; c.scale = 0.5
        c.effects = effects
        var p = Project(); p.width = 200; p.height = 200; p.bg = bg; p.characters = []
        var tr = Track(name: "L1"); tr.clips = [c]; p.tracks = [tr]
        return p
    }
    func render(_ p: Project) throws -> [UInt8] { pixels(try XCTUnwrap(Renderer(project: p, assets: RenderAssets()).renderImage(t: 0.5))) }

    // MARK: クロマキー

    func testChromaKeyMakesGreenTransparentAndKeepsSubject() throws {
        let path = try greenScreenPNG()
        let base = try render(project(path, effects: []))
        let keyed = try render(project(path, effects: [Effect(.chromaKey)]))
        // 画像は 50..150。四隅(緑)は赤い背景が見える
        for (x, y) in [(52, 52), (147, 52), (52, 147), (147, 147)] {
            XCTAssertEqual(base[(y * 200 + x) * 4 + 1], 255, "もとは緑")
            let c = rgb(keyed, x, y)
            XCTAssertGreaterThan(c[0], 250); XCTAssertLessThan(c[1], 5); XCTAssertLessThan(c[2], 5)
            print("CHROMA corner (\(x),\(y)) base=\(rgb(base, x, y)) keyed=\(c)")
        }
        // 被写体(青)は変わらない
        for (x, y) in [(100, 100), (85, 85), (115, 115)] {
            let a = rgb(base, x, y), b = rgb(keyed, x, y)
            for i in 0..<3 { XCTAssertLessThanOrEqual(abs(a[i] - b[i]), 2, "subject \(x),\(y)") }
        }
        print("CHROMA subject base=\(rgb(base, 100, 100)) keyed=\(rgb(keyed, 100, 100))")
        // キャンバスの外側(元から透明)は背景のまま
        XCTAssertEqual(rgb(keyed, 10, 10), [255, 0, 0])
    }

    func testChromaKeyOverLowerLayer() throws {
        let path = try greenScreenPNG()
        var p = project(path, effects: [Effect(.chromaKey)], bg: "#000000")
        // 下のレイヤー: 全面の黄色
        let c = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 0, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        var low = Clip(); low.id = "low"; low.type = .image; low.src = try writePNG(c.makeImage()!, "yellow.png"); low.start = 0; low.duration = 4; low.x = 0.5; low.y = 0.5; low.scale = 2
        var t2 = Track(name: "L2"); t2.clips = [low]
        p.tracks.append(t2)  // 後ろの配列 = 下のレイヤーかは仕様次第。どちらでも四隅が透けるか確認
        let img = try render(p)
        let corner = rgb(img, 55, 55)
        XCTAssertFalse(corner[1] > 200 && corner[0] < 50, "緑が残っていない: \(corner)")
    }

    func testChromaKeyParameters() throws {
        let path = try greenScreenPNG()
        // 許容 0 + なめらかさ 0 でも、ぴったりのキー色は消える
        var e = Effect(.chromaKey); e.params["similarity"] = 0.05; e.params["smoothness"] = 0
        let d = try render(project(path, effects: [e]))
        XCTAssertGreaterThan(rgb(d, 55, 55)[0], 250)
        // 別の色をキーにすると(青)、緑は残り青が消える
        var b = Effect(.chromaKey); b.color = "#1e3cdc"
        let r = try render(project(path, effects: [b]))
        XCTAssertGreaterThan(rgb(r, 55, 55)[1], 200, "緑は残る")
        XCTAssertGreaterThan(rgb(r, 100, 100)[0], 250, "青い被写体が消えて赤い背景")
        // 無効にすれば何もしない
        var off = Effect(.chromaKey); off.enabled = false
        XCTAssertEqual(try render(project(path, effects: [off])), try render(project(path, effects: [])))
    }

    func testChromaCubeValuesAndSpillSuppression() {
        let n = ChromaKey.dimension
        let v = ChromaKey.cubeValues(key: (0, 1, 0), similarity: 0.4, smoothness: 0.1, spill: 0.5)
        func at(_ r: Int, _ g: Int, _ b: Int) -> [Float] { let i = ((b * n + g) * n + r) * 4; return Array(v[i..<i + 4]) }
        XCTAssertEqual(at(0, n - 1, 0)[3], 0, "キー色は透明")
        XCTAssertEqual(at(n - 1, 0, 0)[3], 1, "赤は不透明")
        XCTAssertEqual(at(n - 1, 0, 0)[0], 1)
        // 緑かぶりした肌色(r=.9, g=.8, b=.6)は緑成分が削られる
        let ri = Int(0.7 * Float(n - 1)), gi = Int(0.8 * Float(n - 1)), bi = Int(0.6 * Float(n - 1))
        let skin = at(ri, gi, bi)
        XCTAssertGreaterThan(skin[3], 0.5, "肌色は不透明に近い")
        let noSpill = ChromaKey.cubeValues(key: (0, 1, 0), similarity: 0.4, smoothness: 0.1, spill: 0)
        let j = ((bi * n + gi) * n + ri) * 4
        XCTAssertLessThan(v[j + 1], noSpill[j + 1])
        XCTAssertEqual(noSpill[j + 1], Float(gi) / Float(n - 1), accuracy: 1e-4)
    }

    // MARK: .cube の読み取り

    func identity3D(_ n: Int) -> String {
        var s = "LUT_3D_SIZE \(n)\n"
        for b in 0..<n { for g in 0..<n { for r in 0..<n { s += "\(Float(r) / Float(n - 1)) \(Float(g) / Float(n - 1)) \(Float(b) / Float(n - 1))\n" } } }
        return s
    }
    func inverted3D(_ n: Int) -> String {
        var s = "# invert\nTITLE \"Invert\"\nLUT_3D_SIZE \(n)\n"
        for b in 0..<n { for g in 0..<n { for r in 0..<n { s += "\(1 - Float(r) / Float(n - 1)) \(1 - Float(g) / Float(n - 1)) \(1 - Float(b) / Float(n - 1))\n" } } }
        return s
    }

    func testParseValid3DWithCommentsTitleAndDomain() throws {
        let text = "# comment\nTITLE \"My LUT\"\n\nDOMAIN_MIN 0 0 0\nDOMAIN_MAX 1 1 1  # inline\nLUT_3D_SIZE 2\n" +
            "0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\r\n"
        let l = try CubeLUT.parse(text)
        XCTAssertEqual(l.kind, .d3); XCTAssertEqual(l.size, 2); XCTAssertEqual(l.title, "My LUT")
        XCTAssertEqual(l.table.count, 24); XCTAssertFalse(l.hasCustomDomain)
        XCTAssertEqual(l.sample([0.5, 0.25, 0.75]), [0.5, 0.25, 0.75].map { Float($0) })
        let dom = try CubeLUT.parse("DOMAIN_MIN -1 -1 -1\nDOMAIN_MAX 3 3 3\nLUT_1D_SIZE 2\n0 0 0\n1 1 1\n")
        XCTAssertTrue(dom.hasCustomDomain)
        XCTAssertEqual(dom.sample([1, 1, 1]), [0.5, 0.5, 0.5])
    }

    func testParse1DInterpolates() throws {
        let l = try CubeLUT.parse("LUT_1D_SIZE 3\n0 0 0\n0.8 0.8 0.8\n1 1 1\n")
        XCTAssertEqual(l.kind, .d1)
        XCTAssertEqual(l.sample([0.25, 0.25, 0.25])[0], 0.4, accuracy: 1e-5)
        let (dim, data) = l.cubeData()
        XCTAssertEqual(data.count, dim * dim * dim * 4 * MemoryLayout<Float>.size)
    }

    func testParseRejectsBadInputSafely() {
        let bad: [String] = [
            "", "TITLE \"x\"\n", "LUT_3D_SIZE 2\n0 0 0\n", "LUT_3D_SIZE 1\n0 0 0\n", "LUT_3D_SIZE 9999\n", "LUT_3D_SIZE abc\n",
            "LUT_3D_SIZE 2\n" + String(repeating: "0 0 nan\n", count: 8), "LUT_3D_SIZE 2\n" + String(repeating: "0 0 inf\n", count: 8),
            "LUT_3D_SIZE 2\n" + String(repeating: "0 0\n", count: 8), "LUT_3D_SIZE 2\n" + String(repeating: "0 0 x\n", count: 8),
            "LUT_1D_SIZE 2\nLUT_3D_SIZE 2\n0 0 0\n1 1 1\n", "LUT_1D_SIZE 2\nDOMAIN_MIN 1 1 1\nDOMAIN_MAX 0 0 0\n0 0 0\n1 1 1\n",
            "LUT_1D_SIZE 2\n0 0 0\n1 1 1\n1 1 1\n", "LUT_1D_SIZE 0\n", "LUT_1D_SIZE -3\n",
        ]
        for t in bad { XCTAssertThrowsError(try CubeLUT.parse(t), "should reject: \(t.prefix(40))") }
        // 乱数のごみでも落ちない
        var seed: UInt64 = 7
        for _ in 0..<50 {
            var bytes = [UInt8]()
            for _ in 0..<300 { seed = seed &* 6364136223846793005 &+ 1442695040888963407; bytes.append(UInt8(truncatingIfNeeded: seed >> 33)) }
            _ = try? CubeLUT.parse(String(decoding: bytes, as: UTF8.self))
        }
        XCTAssertThrowsError(try CubeLUT.load(from: tmp.appendingPathComponent("nope.cube")))
    }

    // MARK: LUT の描画(画素)

    func writeCube(_ text: String, _ name: String = "t.cube") throws -> String {
        let u = tmp.appendingPathComponent(name)
        try text.write(to: u, atomically: true, encoding: .utf8)
        return u.path
    }
    func lutFX(_ path: String?, _ intensity: Double = 1) -> Effect { var e = Effect(.lut); e.path = path; e.params["intensity"] = intensity; return e }

    func testIdentityLUTLeavesPixelsUnchanged() throws {
        let img = try gradientPNG()
        let base = try render(project(img, effects: []))
        let cube = try writeCube(identity3D(17))
        let out = try render(project(img, effects: [lutFX(cube)]))
        var maxDiff = 0
        for y in stride(from: 52, to: 148, by: 3) { for x in stride(from: 52, to: 148, by: 3) {
            let a = rgb(base, x, y), b = rgb(out, x, y)
            for i in 0..<3 { maxDiff = max(maxDiff, abs(a[i] - b[i])) }
        } }
        print("LUT identity max diff = \(maxDiff)")
        XCTAssertLessThanOrEqual(maxDiff, 2)
        // 1D の恒等も同じ
        let one = try writeCube("LUT_1D_SIZE 2\n0 0 0\n1 1 1\n", "id1.cube")
        let out1 = try render(project(img, effects: [lutFX(one)]))
        for (x, y) in [(60, 60), (100, 100), (140, 90)] { for i in 0..<3 { XCTAssertLessThanOrEqual(abs(rgb(base, x, y)[i] - rgb(out1, x, y)[i]), 2) } }
        // 範囲(DOMAIN)つきの恒等
        let dom = try writeCube("DOMAIN_MIN 0 0 0\nDOMAIN_MAX 2 2 2\nLUT_1D_SIZE 2\n0 0 0\n1 1 1\n", "dom.cube")
        let outD = try render(project(img, effects: [lutFX(dom)]))
        let a = rgb(base, 100, 100), b = rgb(outD, 100, 100)
        // domain 0..2 に 0..1 の入力 → 出力は半分の明るさ
        for i in 0..<3 { XCTAssertEqual(Double(b[i]), Double(a[i]) / 2, accuracy: 3) }
    }

    func testInvertingLUTInvertsPixelsAndIntensityMixes() throws {
        let img = try gradientPNG()
        let base = try render(project(img, effects: []))
        let cube = try writeCube(inverted3D(17))
        let out = try render(project(img, effects: [lutFX(cube)]))
        var maxDiff = 0
        for y in stride(from: 52, to: 148, by: 3) { for x in stride(from: 52, to: 148, by: 3) {
            let a = rgb(base, x, y), b = rgb(out, x, y)
            for i in 0..<3 { maxDiff = max(maxDiff, abs((255 - a[i]) - b[i])) }
        } }
        print("LUT invert max diff = \(maxDiff); sample base=\(rgb(base, 100, 100)) out=\(rgb(out, 100, 100))")
        XCTAssertLessThanOrEqual(maxDiff, 3)
        // 強さ 0.5 はちょうど真ん中(255 の半分)付近へ。0 は何もしない
        let half = try render(project(img, effects: [lutFX(cube, 0.5)]))
        let a = rgb(base, 100, 100), h = rgb(half, 100, 100)
        for i in 0..<3 { XCTAssertEqual(Double(h[i]), (Double(a[i]) + Double(255 - a[i])) / 2, accuracy: 4) }
        XCTAssertEqual(try render(project(img, effects: [lutFX(cube, 0)])), base)
    }

    func testMissingOrBrokenLUTFileDoesNothing() throws {
        let img = try gradientPNG()
        let base = try render(project(img, effects: []))
        XCTAssertEqual(try render(project(img, effects: [lutFX("/no/such/file.cube")])), base)
        XCTAssertEqual(try render(project(img, effects: [lutFX(nil)])), base)
        let broken = try writeCube("LUT_3D_SIZE 2\ngarbage\n", "broken.cube")
        XCTAssertEqual(try render(project(img, effects: [lutFX(broken)])), base)
        XCTAssertEqual(LUTCache.shared.status(atPath: broken), .invalid)
        XCTAssertEqual(LUTCache.shared.status(atPath: "/no/such/file.cube"), .missing)
        XCTAssertEqual(LUTCache.shared.status(atPath: try writeCube(identity3D(2), "ok.cube")), .ok)
    }

    func testLUTCacheReloadsWhenTheFileChanges() throws {
        let img = try gradientPNG()
        let path = try writeCube(identity3D(5), "swap.cube")
        let a = try render(project(img, effects: [lutFX(path)]))
        Thread.sleep(forTimeInterval: 1.1)
        try inverted3D(5).write(toFile: path, atomically: true, encoding: .utf8)
        let b = try render(project(img, effects: [lutFX(path)]))
        XCTAssertNotEqual(a, b)
    }

    // MARK: ファイル・編集

    func testEffectPathRoundTripAndDefaultsAreNotWritten() throws {
        XCTAssertNil(Effect(.chromaKey).path)
        var e = Effect(.lut); e.path = "/x/y.cube"
        let data = try JSONEncoder().encode(e)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"path\""))
        XCTAssertEqual(try JSONDecoder().decode(Effect.self, from: data), e)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(Effect(.brightness)), as: UTF8.self).contains("path"))
        XCTAssertEqual(Effect(.chromaKey).colorOrDefault, "#00ff00")
        XCTAssertEqual(EffectKind.chromaKey.label, "クロマキー")
    }

    func testSetLUTPathAddsOnceAndNoOpIsFalse() {
        var c = Clip(); c.type = .video
        XCTAssertTrue(EffectEditing.setLUTPath(&c, "/a.cube"))
        XCTAssertEqual(c.effects.count, 1); XCTAssertEqual(c.effects[0].path, "/a.cube")
        XCTAssertFalse(EffectEditing.setLUTPath(&c, "/a.cube"), "同じなら何もしない")
        XCTAssertTrue(EffectEditing.setLUTPath(&c, "/b.cube"))
        XCTAssertEqual(c.effects.count, 1, "足さずに差し替え"); XCTAssertEqual(c.effects[0].path, "/b.cube")
        XCTAssertFalse(EffectEditing.setLUTPath(&c, ""))
        var audio = Clip(); audio.type = .audio
        XCTAssertFalse(EffectEditing.setLUTPath(&audio, "/a.cube"))
        // 初期値に戻してもファイルは残る
        c.effects[0].params["intensity"] = 0.3
        XCTAssertTrue(EffectEditing.reset(&c, at: 0))
        XCTAssertEqual(c.effects[0].path, "/b.cube")
    }

    // MARK: 速度(ms/フレーム)

    func testBenchMillisecondsPerFrame1080p() throws {
        let img = try gradientPNG()
        let cube = try writeCube(identity3D(33), "bench.cube")
        func bench(_ fx: [Effect]) throws -> Double {
            var p = project(img, effects: fx)
            p.width = 1920; p.height = 1080
            p.tracks[0].clips[0].scale = 1
            let r = Renderer(project: p, assets: RenderAssets())
            _ = r.renderImage(t: 0.5)
            let n = 20, t0 = Date()
            for _ in 0..<n { _ = r.renderImage(t: 0.5) }
            return Date().timeIntervalSince(t0) * 1000 / Double(n)
        }
        let none = try bench([]), key = try bench([Effect(.chromaKey)]), lut = try bench([lutFX(cube)]), br = try bench([Effect(.brightness)])
        print("BENCH 1080p ms/frame: none=\(none) brightness=\(br) chromaKey=\(key) lut33=\(lut)")
    }
}
