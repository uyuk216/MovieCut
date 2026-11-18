import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import MovieCutCore

/// 色調転写(#58): 統計の計算・写像・立方体・描画(画素)・参照ファイル・編集。
/// LUT のパースと適用のテストは ChromaLUTTests が担う(ここでは LUT との共存も確認する)。
final class ColorTransferTests: XCTestCase {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("color-transfer-\(UUID().uuidString)")
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

    func solidPNG(r: Double, g: Double, b: Double, size: Int = 40, name: String) throws -> String {
        let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: 1))
        c.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return try writePNG(c.makeImage()!, name)
    }

    /// 左半分が暗い色・右半分が明るい色の画像(平均と分散が手計算できる)。
    func twoTonePNG(size: Int = 40, name: String = "two.png") throws -> String {
        let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: size / 2, height: size))
        c.setFillColor(CGColor(srgbRed: 0.6, green: 0.8, blue: 1.0, alpha: 1)); c.fill(CGRect(x: size / 2, y: 0, width: size - size / 2, height: size))
        return try writePNG(c.makeImage()!, name)
    }

    func project(_ path: String, effects: [Effect], bg: String = "#000000") -> Project {
        var c = Clip(); c.id = "i"; c.type = .image; c.src = path; c.start = 0; c.duration = 4; c.x = 0.5; c.y = 0.5; c.scale = 0.5
        c.effects = effects
        var p = Project(); p.width = 200; p.height = 200; p.bg = bg; p.characters = []
        var tr = Track(name: "L1"); tr.clips = [c]; p.tracks = [tr]
        return p
    }
    func render(_ p: Project) throws -> [UInt8] { pixels(try XCTUnwrap(Renderer(project: p, assets: RenderAssets()).renderImage(t: 0.5))) }

    func transferFX(_ path: String?, _ intensity: Double = 1) -> Effect {
        var e = Effect(.colorTransfer); e.path = path; e.params["intensity"] = intensity; return e
    }

    // MARK: 統計

    func testStatsOfKnownPixels() {
        // 2 画素: (0.2, 0.4, 0.6) と (0.6, 0.8, 1.0)。平均 (0.4, 0.6, 0.8)、標準偏差 (0.2, 0.2, 0.2)
        var rgba = [UInt8]()
        for (r, g, b) in [(0.2, 0.4, 0.6), (0.6, 0.8, 1.0)] {
            rgba += [UInt8(r * 255), UInt8(g * 255), UInt8(b * 255), 255]
        }
        let s = ColorTransfer.stats(rgba: rgba, count: 2)!
        for c in 0..<3 {
            XCTAssertEqual(s.mean[c], [0.4, 0.6, 0.8][c], accuracy: 0.01)
            XCTAssertEqual(s.std[c], 0.2, accuracy: 0.01)
        }
    }

    func testStatsIgnoresTransparentPixels() {
        // 不透明な赤 1 画素 + 透明な(黒に潰れた)画素 3 つ。透明を数えると平均が黒へ引っ張られる
        var rgba: [UInt8] = [255, 0, 0, 255]
        for _ in 0..<3 { rgba += [0, 0, 0, 0] }
        let s = ColorTransfer.stats(rgba: rgba, count: 4)!
        XCTAssertEqual(s.mean[0], 1, accuracy: 0.01)
        XCTAssertEqual(s.mean[1], 0, accuracy: 0.01)
        // 全部透明なら nil
        XCTAssertNil(ColorTransfer.stats(rgba: [UInt8](repeating: 0, count: 16), count: 4))
        XCTAssertNil(ColorTransfer.stats(rgba: [], count: 0))
    }

    func testStatsOfFiles() throws {
        let solid = try solidPNG(r: 0.25, g: 0.5, b: 0.75, name: "solid.png")
        let s = try XCTUnwrap(ColorTransfer.stats(ofFile: solid))
        XCTAssertEqual(s.mean[0], 0.25, accuracy: 0.01); XCTAssertEqual(s.mean[1], 0.5, accuracy: 0.01); XCTAssertEqual(s.mean[2], 0.75, accuracy: 0.01)
        for c in 0..<3 { XCTAssertEqual(s.std[c], 0, accuracy: 0.01, "単色は分散なし") }
        let two = try twoTonePNG()
        let t = try XCTUnwrap(ColorTransfer.stats(ofFile: two))
        XCTAssertEqual(t.mean[0], 0.4, accuracy: 0.02); XCTAssertEqual(t.std[0], 0.2, accuracy: 0.02)
        XCTAssertNil(ColorTransfer.stats(ofFile: "/no/such/file.png"))
        let text = tmp.appendingPathComponent("notanimage.txt")
        try "hello".write(to: text, atomically: true, encoding: .utf8)
        XCTAssertNil(ColorTransfer.stats(ofFile: text.path))
        XCTAssertEqual(ReferenceColorCache.shared.status(atPath: solid), .ok)
        XCTAssertEqual(ReferenceColorCache.shared.status(atPath: "/no/such/file.png"), .missing)
        XCTAssertEqual(ReferenceColorCache.shared.status(atPath: text.path), .invalid)
    }

    // MARK: 写像

    func testTransferredMapping() {
        let src = ColorTransfer.Stats(mean: [0.4, 0.6, 0.8], std: [0.2, 0.2, 0.2])
        let ref = ColorTransfer.Stats(mean: [0.5, 0.5, 0.5], std: [0.1, 0.1, 0.1])
        // 元の平均色は参照の平均色へ
        let m = ColorTransfer.transferred([0.4, 0.6, 0.8], src: src, ref: ref, strength: 1)
        for c in 0..<3 { XCTAssertEqual(m[c], 0.5, accuracy: 1e-9) }
        // 平均 + 1σ の色は 参照の平均 + 1σ へ
        let p = ColorTransfer.transferred([0.6, 0.8, 1.0], src: src, ref: ref, strength: 1)
        for c in 0..<3 { XCTAssertEqual(p[c], 0.6, accuracy: 1e-9) }
        // 強さ 0 は恒等、0.5 は中点
        XCTAssertEqual(ColorTransfer.transferred([0.13, 0.57, 0.91], src: src, ref: ref, strength: 0), [0.13, 0.57, 0.91])
        let h = ColorTransfer.transferred([0.4, 0.6, 0.8], src: src, ref: ref, strength: 0.5)
        XCTAssertEqual(h[0], 0.45, accuracy: 1e-9)
        // 範囲外へ出ない(強い拡大でも 0〜1 に収まる)
        let wide = ColorTransfer.Stats(mean: [0.5, 0.5, 0.5], std: [0.4, 0.4, 0.4])
        let o = ColorTransfer.transferred([1, 0, 0.5], src: src, ref: wide, strength: 1)
        for v in o { XCTAssertTrue(v >= 0 && v <= 1) }
        // 参照が単色(std 0)なら、平均色はその色に一致する
        let flat = ColorTransfer.Stats(mean: [0.9, 0.3, 0.1], std: [0, 0, 0])
        XCTAssertEqual(ColorTransfer.transferred([0.4, 0.6, 0.8], src: src, ref: flat, strength: 1), [0.9, 0.3, 0.1])
    }

    func testCubeDataMatchesMapping() {
        let src = ColorTransfer.Stats(mean: [0.4, 0.6, 0.8], std: [0.2, 0.2, 0.2])
        let ref = ColorTransfer.Stats(mean: [0.5, 0.5, 0.5], std: [0.1, 0.1, 0.1])
        let n = 5
        let data = ColorTransfer.cubeData(src: src, ref: ref, strength: 1, dimension: n)
        XCTAssertEqual(data.count, n * n * n * 4 * MemoryLayout<Float>.size)
        let floats = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        func at(_ r: Int, _ g: Int, _ b: Int) -> [Float] { let i = ((b * n + g) * n + r) * 4; return Array(floats[i..<i + 4]) }
        // 格子点 (0.5, 0.5, 0.5) は写像どおり: (0.5-0.4)*0.5+0.5=0.55, (0.5-0.6)*0.5+0.5=0.45, (0.5-0.8)*0.5+0.5=0.35
        let mid = at(2, 2, 2)
        XCTAssertEqual(mid[0], 0.55, accuracy: 1e-5); XCTAssertEqual(mid[1], 0.45, accuracy: 1e-5); XCTAssertEqual(mid[2], 0.35, accuracy: 1e-5)
        XCTAssertEqual(mid[3], 1)
    }

    // MARK: 描画(画素)

    func testRenderTransfersToneToReference() throws {
        // 元: 平均 (0.4, 0.6, 0.8) の 2 色画像。参照: 平均 (0.5, 0.5, 0.5)・σ 0.1 の 2 色画像
        let srcPath = try twoTonePNG(name: "src.png")
        let refCtx = CGContext(data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        refCtx.setFillColor(CGColor(srgbRed: 0.4, green: 0.4, blue: 0.4, alpha: 1)); refCtx.fill(CGRect(x: 0, y: 0, width: 20, height: 40))
        refCtx.setFillColor(CGColor(srgbRed: 0.6, green: 0.6, blue: 0.6, alpha: 1)); refCtx.fill(CGRect(x: 20, y: 0, width: 20, height: 40))
        let refPath = try writePNG(refCtx.makeImage()!, "ref.png")

        let base = try render(project(srcPath, effects: []))
        let out = try render(project(srcPath, effects: [transferFX(refPath)]))
        // 画像は 50..150 に表示。暗い側の代表点(75, 100)と明るい側(125, 100)
        // 元の暗い側 (0.2,0.4,0.6) = 平均-1σ → 転写後は (0.4,0.4,0.4)。明るい側は (0.6,0.6,0.6)
        let dark = rgb(out, 75, 100), bright = rgb(out, 125, 100)
        for c in 0..<3 {
            XCTAssertEqual(Double(dark[c]), 0.4 * 255, accuracy: 8, "dark ch\(c): \(dark)")
            XCTAssertEqual(Double(bright[c]), 0.6 * 255, accuracy: 8, "bright ch\(c): \(bright)")
        }
        XCTAssertNotEqual(rgb(base, 75, 100), dark)
        print("TRANSFER dark base=\(rgb(base, 75, 100)) out=\(dark); bright base=\(rgb(base, 125, 100)) out=\(bright)")
    }

    func testRenderSolidSourceTakesReferenceColor() throws {
        // 単色の元(0.3, 0.3, 0.3) + 単色の参照(0.8, 0.5, 0.2) → 全体が参照の色になる
        let srcPath = try solidPNG(r: 0.3, g: 0.3, b: 0.3, name: "gray.png")
        let refPath = try solidPNG(r: 0.8, g: 0.5, b: 0.2, name: "warm.png")
        let out = try render(project(srcPath, effects: [transferFX(refPath)]))
        let c = rgb(out, 100, 100)
        XCTAssertEqual(Double(c[0]), 0.8 * 255, accuracy: 6); XCTAssertEqual(Double(c[1]), 0.5 * 255, accuracy: 6); XCTAssertEqual(Double(c[2]), 0.2 * 255, accuracy: 6)
    }

    func testRenderIntensityZeroAndMissingReferenceDoNothing() throws {
        let srcPath = try twoTonePNG(name: "src2.png")
        let refPath = try solidPNG(r: 0.8, g: 0.5, b: 0.2, name: "warm2.png")
        let base = try render(project(srcPath, effects: []))
        XCTAssertEqual(try render(project(srcPath, effects: [transferFX(refPath, 0)])), base, "強さ 0 は速い道で画素一致")
        XCTAssertEqual(try render(project(srcPath, effects: [transferFX("/no/such/ref.png")])), base, "参照が無ければ何もしない")
        XCTAssertEqual(try render(project(srcPath, effects: [transferFX(nil)])), base, "参照未選択は何もしない")
        // 強さ 0.5 は元と全転写の中間付近
        let full = try render(project(srcPath, effects: [transferFX(refPath, 1)]))
        let half = try render(project(srcPath, effects: [transferFX(refPath, 0.5)]))
        for ch in 0..<3 {
            let b = Double(rgb(base, 75, 100)[ch]), f = Double(rgb(full, 75, 100)[ch]), h = Double(rgb(half, 75, 100)[ch])
            XCTAssertEqual(h, (b + f) / 2, accuracy: 6, "half ch\(ch)")
        }
    }

    func testLUTAndColorTransferCoexist() throws {
        // LUT(反転) → 色調転写 の順に両方かけても落ちず、結果が単独とも元の絵とも違う
        var s = "LUT_3D_SIZE 2\n"
        for b in 0..<2 { for g in 0..<2 { for r in 0..<2 { s += "\(1 - r) \(1 - g) \(1 - b)\n" } } }
        let cubeURL = tmp.appendingPathComponent("inv.cube")
        try s.write(to: cubeURL, atomically: true, encoding: .utf8)
        var lut = Effect(.lut); lut.path = cubeURL.path
        let srcPath = try twoTonePNG(name: "src3.png")
        let refPath = try solidPNG(r: 0.8, g: 0.5, b: 0.2, name: "warm3.png")
        let base = try render(project(srcPath, effects: []))
        let both = try render(project(srcPath, effects: [lut, transferFX(refPath)]))
        XCTAssertNotEqual(both, base)
        let lutOnly = try render(project(srcPath, effects: [lut]))
        XCTAssertNotEqual(both, lutOnly)
    }

    // MARK: 編集

    func testSetColorTransferPathAddsOnceAndReplaces() {
        var c = Clip(); c.type = .video
        XCTAssertTrue(EffectEditing.setColorTransferPath(&c, "/ref.png"))
        XCTAssertEqual(c.effects.count, 1); XCTAssertEqual(c.effects[0].kind, EffectKind.colorTransfer.rawValue)
        XCTAssertEqual(c.effects[0].path, "/ref.png")
        XCTAssertFalse(EffectEditing.setColorTransferPath(&c, "/ref.png"))
        XCTAssertTrue(EffectEditing.setColorTransferPath(&c, "/other.jpg"))
        XCTAssertEqual(c.effects.count, 1); XCTAssertEqual(c.effects[0].path, "/other.jpg")
        XCTAssertFalse(EffectEditing.setColorTransferPath(&c, ""))
        var audio = Clip(); audio.type = .audio
        XCTAssertFalse(EffectEditing.setColorTransferPath(&audio, "/ref.png"))
        // LUT とは別々に持てる
        XCTAssertTrue(EffectEditing.setLUTPath(&c, "/a.cube"))
        XCTAssertEqual(c.effects.count, 2)
        // 初期値に戻しても参照ファイルは残る
        c.effects[0].params["intensity"] = 0.3
        XCTAssertTrue(EffectEditing.reset(&c, at: 0))
        XCTAssertEqual(c.effects[0].path, "/other.jpg")
    }

    func testEffectKindBasics() {
        XCTAssertEqual(EffectKind.colorTransfer.label, "色調転写")
        let e = Effect(.colorTransfer)
        XCTAssertEqual(e.value("intensity"), 1)
        XCTAssertNil(e.color)
    }
}
