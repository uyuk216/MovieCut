import XCTest
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import MovieCutCore

/// フィルムグレイン(輝度のノイズを粒状に足す)。種類・引数・解決・画素。
final class FilmGrainTests: XCTestCase {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("grain-tests-\(UUID().uuidString)")
    override func setUpWithError() throws { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    struct Pixels {
        let w: Int, h: Int
        var d: [UInt8]
        func rgb(_ x: Int, _ y: Int) -> [Int] { let i = (y * w + x) * 4; return [Int(d[i]), Int(d[i + 1]), Int(d[i + 2])] }
        func alpha(_ x: Int, _ y: Int) -> Int { Int(d[(y * w + x) * 4 + 3]) }
        func luma(_ x: Int, _ y: Int) -> Double { let c = rgb(x, y); return 0.2126 * Double(c[0]) + 0.7152 * Double(c[1]) + 0.0722 * Double(c[2]) }
    }

    func pixels(_ img: CGImage) -> Pixels {
        var d = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let c = CGContext(data: &d, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return Pixels(w: img.width, h: img.height, d: d)
    }

    /// 一様なグレー(不透明)の CIImage。
    func flatImage(gray: CGFloat = 0.5, n: Int = 64) -> CIImage {
        let c = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(gray: gray, alpha: 1); c.fill(CGRect(x: 0, y: 0, width: n, height: n))
        return CIImage(cgImage: c.makeImage()!)
    }

    func render(_ img: CIImage) throws -> Pixels {
        pixels(try XCTUnwrap(EffectPipeline.makeImage(img, from: img.extent)))
    }

    // MARK: 種類と引数

    func testKindLabelParamsAndDefaults() {
        XCTAssertEqual(EffectKind.filmGrain.label, "フィルムグレイン")
        XCTAssertEqual(EffectKind.filmGrain.params.map(\.key), ["amount", "size"])
        let e = Effect(.filmGrain)
        XCTAssertEqual(e.known, .filmGrain)
        XCTAssertEqual(e.value("amount"), 0.35)
        XCTAssertEqual(e.value("size"), 2)
        XCTAssertNil(EffectKind.filmGrain.defaultColor)
    }

    func testRoundTripThroughJSON() throws {
        var e = Effect(.filmGrain)
        e.params["amount"] = 0.8
        let data = try JSONEncoder().encode(e)
        let back = try JSONDecoder().decode(Effect.self, from: data)
        XCTAssertEqual(back, e)
        XCTAssertEqual(back.known, .filmGrain)
    }

    func testResolveExcludesZeroAmount() {
        var c = Clip(); c.type = .image
        var off = Effect(.filmGrain); off.params["amount"] = 0
        c.effects = [off]
        XCTAssertTrue(EffectPipeline.resolve(c, atClipTime: 0).isEmpty, "強さ 0 は何もしない")
        var on = Effect(.filmGrain); on.params["amount"] = 0.5
        c.effects = [on]
        XCTAssertEqual(EffectPipeline.resolve(c, atClipTime: 0).map(\.kind), [.filmGrain])
    }

    // MARK: 画素

    func testGrainAddsSpatialVariationAndKeepsMean() throws {
        let base = flatImage()
        let out = try render(FilmGrain.apply(base, amount: 1, size: 2))
        var lo = 255.0, hi = 0.0, sum = 0.0
        for y in 0..<64 { for x in 0..<64 { let l = out.luma(x, y); lo = min(lo, l); hi = max(hi, l); sum += l } }
        XCTAssertGreaterThan(hi - lo, 60, "一様な絵に粒のばらつきが乗る")
        XCTAssertEqual(sum / (64 * 64), 128, accuracy: 60, "平均の明るさが大きくは外れない")
        XCTAssertTrue((0..<64).allSatisfy { out.alpha($0, 0) == 255 }, "不透明は不透明のまま")
    }

    func testGrainDoesNotPaintTransparentArea() throws {
        // 左半分は透明、右半分は不透明なグレー
        let n = 64
        let c = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(gray: 0.5, alpha: 1); c.fill(CGRect(x: 32, y: 0, width: 32, height: n))
        let img = CIImage(cgImage: c.makeImage()!)
        let out = try render(FilmGrain.apply(img, amount: 1, size: 2))
        for y in stride(from: 0, to: n, by: 7) {
            for x in 0..<32 { XCTAssertEqual(out.alpha(x, y), 0, "透明な所には粒を足さない") }
            for x in 32..<n { XCTAssertEqual(out.alpha(x, y), 255) }
        }
    }

    func testZeroAmountIsIdentity() throws {
        let base = flatImage()
        let a = try render(base)
        let b = try render(FilmGrain.apply(base, amount: 0, size: 2))
        XCTAssertEqual(a.d, b.d)
    }

    // MARK: 描画経路(プレビュー・書き出し共通)

    func grayPNG(n: Int = 64) throws -> String {
        let c = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(gray: 0.5, alpha: 1); c.fill(CGRect(x: 0, y: 0, width: n, height: n))
        let url = tmp.appendingPathComponent("gray.png")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, c.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url.path
    }

    func testRendererAppliesGrain() throws {
        let path = try grayPNG()
        func project(_ effects: [Effect]) -> Project {
            var c = Clip(); c.id = "i"; c.type = .image; c.src = path; c.start = 0; c.duration = 4; c.x = 0.5; c.y = 0.5; c.scale = 1
            c.effects = effects
            var p = Project(); p.width = 64; p.height = 64; p.bg = "#000000"; p.characters = []
            var tr = Track(name: "L1"); tr.clips = [c]; p.tracks = [tr]
            return p
        }
        func rendered(_ p: Project) throws -> Pixels {
            pixels(try XCTUnwrap(Renderer(project: p, assets: RenderAssets()).renderImage(t: 0.5)))
        }
        let flat = try rendered(project([]))
        XCTAssertEqual(Set((0..<64).map { flat.luma($0, 32) }).count, 1, "エフェクトなしは一様")
        var e = Effect(.filmGrain); e.params["amount"] = 1
        let grained = try rendered(project([e]))
        XCTAssertGreaterThan(Set((0..<64).map { grained.luma($0, 32) }).count, 20, "描画経路でも粒が乗る")
    }
}
