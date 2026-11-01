import XCTest
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import MovieCutCore

/// 形のマスク(矩形・楕円・反転・羽根)と、ファイルの書き方、描画(Renderer)での効き方。
final class ClipMaskTests: XCTestCase {
    private let W = 200.0, H = 200.0

    /// 200×200 の赤を、マスクで切ったあとの画素(RGBA・0〜255)。左上原点の (x, y)。
    private func masked(_ m: ClipMask) -> (Int, Int) -> [Int] {
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: W, height: H))
        let out = ShapeMask.apply(red, mask: m, canvasWidth: W, canvasHeight: H, originX: 0, originY: 0)
        let cg = EffectPipeline.makeImage(out, from: CGRect(x: 0, y: 0, width: W, height: H))!
        var d = [UInt8](repeating: 0, count: 200 * 200 * 4)
        let c = CGContext(data: &d, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 800,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(cg, in: CGRect(x: 0, y: 0, width: 200, height: 200))
        return { x, y in let i = (y * 200 + x) * 4; return [Int(d[i]), Int(d[i + 1]), Int(d[i + 2]), Int(d[i + 3])] }
    }

    func testRectKeepsInsideAndClearsOutside() {
        let px = masked(ClipMask())   // 矩形 (0.25..0.75)
        XCTAssertEqual(px(100, 100)[3], 255, "中は残る")
        XCTAssertEqual(px(5, 5)[3], 0, "外は透明")
        XCTAssertEqual(px(60, 100)[3], 255, "辺の内側は残る")
        XCTAssertEqual(px(40, 100)[3], 0, "辺の外側は透明")
        XCTAssertEqual(px(100, 100)[0], 255, "残った所は元の色")
    }

    func testEllipseClearsItsCornersInsideTheRect() {
        let px = masked(ClipMask(shape: "ellipse"))
        XCTAssertEqual(px(100, 100)[3], 255)
        XCTAssertEqual(px(55, 55)[3], 0, "矩形の中でも、楕円の外の角は透明")
        XCTAssertEqual(px(60, 100)[3], 255, "楕円の内側")
    }

    func testInvertKeepsOutsideAndClearsInside() {
        let px = masked(ClipMask(invert: true))
        XCTAssertEqual(px(100, 100)[3], 0)
        XCTAssertEqual(px(5, 5)[3], 255)
    }

    func testFeatherGradientIsMonotonicAcrossTheEdge() {
        let px = masked(ClipMask(feather: 0.5))
        // 左の辺は x = 50。内から外へ(x を減らす)アルファは単調に減る
        let row = (30...70).map { px($0, 100)[3] }
        for i in 1..<row.count { XCTAssertGreaterThanOrEqual(row[i], row[i - 1], "x=\(30 + i)") }
        XCTAssertTrue(row.contains { $0 > 20 && $0 < 235 }, "羽根のぶんだけ中間の値がある: \(row)")
        XCTAssertEqual(px(100, 100)[3], 255)
        // 楕円の羽根も、中心から外へ単調に減る
        let round = masked(ClipMask(shape: "ellipse", feather: 0.6))
        let radial = (100...190).map { round($0, 100)[3] }
        for i in 1..<radial.count { XCTAssertLessThanOrEqual(radial[i], radial[i - 1], "x=\(100 + i)") }
    }

    func testFileWritesOnlyNonDefaultFields() throws {
        var c = Clip()
        c.type = .image
        XCTAssertFalse(String(data: try JSONEncoder().encode(c), encoding: .utf8)!.contains("\"mask\""), "マスクが無いクリップは書かない")
        c.mask = ClipMask()
        let json = String(data: try JSONEncoder().encode(c), encoding: .utf8)!
        XCTAssertTrue(json.contains("\"mask\""))
        XCTAssertFalse(json.contains("feather"), "羽根が 0 のときは書かない")
        XCTAssertFalse(json.contains("invert"), "反転が無いときは書かない")
        let back = try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(back.mask, ClipMask())
        c.mask = ClipMask(shape: "ellipse", feather: 0.3, invert: true)
        let again = try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(again.mask, c.mask)
    }

    func testUnknownShapeFallsBackToRectAndOutOfRangeIsClamped() throws {
        let m = ClipMask(shape: "star", x: 3, y: -1, w: 0, h: 9, feather: 7)
        XCTAssertEqual(m.shape, "rect")
        XCTAssertEqual(m.x, 1); XCTAssertEqual(m.y, 0); XCTAssertEqual(m.w, 0.01); XCTAssertEqual(m.h, 1); XCTAssertEqual(m.feather, 1)
    }

    /// 描画の入口: 画像クリップにマスクをかけると、マスクの外は背景の色になる。
    func testRendererAppliesMaskAfterEffectsOnTheClip() throws {
        let dir = NSTemporaryDirectory() + "clipmask-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/red.png"
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(ctx.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))

        var p = Project.new()
        p.bg = "#0000ff"                       // 背景は青
        var c = Clip()
        c.id = "img"; c.type = .image; c.start = 0; c.duration = 2; c.src = path
        c.mask = ClipMask(x: 0.4, y: 0.4, w: 0.2, h: 0.2)   // 中央の小さな矩形だけ残す
        p.tracks[0].clips = [c]
        let img = try XCTUnwrap(Renderer(project: p, assets: RenderAssets()).renderImage(t: 0.5))
        var d = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let g = CGContext(data: &d, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        g.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        func at(_ x: Double, _ y: Double) -> [Int] {
            let i = (Int(y * Double(img.height)) * img.width + Int(x * Double(img.width))) * 4
            return [Int(d[i]), Int(d[i + 1]), Int(d[i + 2])]
        }
        XCTAssertGreaterThan(at(0.5, 0.5)[0], 200, "中央は赤(残る)")
        XCTAssertLessThan(at(0.5, 0.5)[2], 60)
        XCTAssertGreaterThan(at(0.1, 0.5)[2], 200, "マスクの外は背景の青")
        XCTAssertLessThan(at(0.1, 0.5)[0], 60)
    }
}
