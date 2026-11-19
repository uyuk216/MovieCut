import XCTest
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import MovieCutCore

/// ペンマスク(ベジェの閉じたパス): ラスタライズの内外・曲線の膨らみ・羽根・反転、
/// 内外判定の純粋計算、保存/復元と既存形状(矩形・楕円)の互換、Renderer での効き方。
final class PenMaskTests: XCTestCase {
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

    /// まっすぐな正方形のペン(0.25〜0.75)。
    private func square() -> ClipMask {
        ClipMask(shape: "pen", points: [
            MaskPoint(x: 0.25, y: 0.25), MaskPoint(x: 0.75, y: 0.25),
            MaskPoint(x: 0.75, y: 0.75), MaskPoint(x: 0.25, y: 0.75),
        ])
    }

    func testStraightPenKeepsInsideAndClearsOutside() {
        let px = masked(square())
        XCTAssertEqual(px(100, 100)[3], 255, "中は残る")
        XCTAssertEqual(px(100, 100)[0], 255, "残った所は元の色")
        XCTAssertEqual(px(5, 5)[3], 0, "外は透明")
        XCTAssertEqual(px(60, 100)[3], 255, "辺の内側は残る")
        XCTAssertEqual(px(40, 100)[3], 0, "辺の外側は透明")
    }

    /// 上下非対称の三角形で、上下が反転していないことを確かめる。
    func testPenOrientationTopStaysTop() {
        // 左上原点で A(0.1,0.1) B(0.9,0.1) C(0.1,0.9): 上辺と左辺と斜辺。x+y<1 が内側。
        let tri = ClipMask(shape: "pen", points: [
            MaskPoint(x: 0.1, y: 0.1), MaskPoint(x: 0.9, y: 0.1), MaskPoint(x: 0.1, y: 0.9),
        ])
        let px = masked(tri)
        XCTAssertEqual(px(100, 30)[3], 255, "上寄りの内側は残る")
        XCTAssertEqual(px(30, 30)[3], 255, "左上の内側は残る")
        XCTAssertEqual(px(100, 170)[3], 0, "下寄りは斜辺の外")
        XCTAssertEqual(px(170, 170)[3], 0, "右下は外")
        XCTAssertTrue(tri.penContains(u: 0.5, v: 0.15))
        XCTAssertFalse(tri.penContains(u: 0.5, v: 0.85))
    }

    /// 上辺が上へ膨らむベジェ: 直線の弦より上(外側だった所)が内側になり、曲線より上は外のまま。
    func testBezierBulgeExpandsTheShape() {
        let m = ClipMask(shape: "pen", points: [
            MaskPoint(x: 0.2, y: 0.35, outX: 0.5, outY: 0.05),
            MaskPoint(x: 0.8, y: 0.35, inX: 0.5, inY: 0.05),
            MaskPoint(x: 0.8, y: 0.8),
            MaskPoint(x: 0.2, y: 0.8),
        ])
        // 純粋計算: 曲線の頂点は中心で y≈0.125。弦は y=0.35。
        XCTAssertTrue(m.penContains(u: 0.5, v: 0.2), "弦の外・曲線の内は内側")
        XCTAssertFalse(m.penContains(u: 0.5, v: 0.08), "曲線より上は外側")
        XCTAssertTrue(m.penContains(u: 0.5, v: 0.6), "本体は内側")
        XCTAssertFalse(m.penContains(u: 0.05, v: 0.6), "左右の外は外側")
        // 画素でも同じになる
        let px = masked(m)
        XCTAssertEqual(px(100, 40)[3], 255, "膨らみの内側は残る")
        XCTAssertEqual(px(100, 16)[3], 0, "曲線より上は透明")
        XCTAssertEqual(px(100, 120)[3], 255)
    }

    func testPenInvertAndFeather() {
        let inv = masked(ClipMask(shape: "pen", invert: true, points: square().points))
        XCTAssertEqual(inv(100, 100)[3], 0, "反転で中が透明")
        XCTAssertEqual(inv(5, 5)[3], 255, "反転で外が残る")

        let px = masked(ClipMask(shape: "pen", feather: 0.5, points: square().points))
        let row = (30...70).map { px($0, 100)[3] }   // 左の辺は x=50
        for i in 1..<row.count { XCTAssertGreaterThanOrEqual(row[i], row[i - 1], "x=\(30 + i)") }
        XCTAssertTrue(row.contains { $0 > 20 && $0 < 235 }, "羽根のぶんだけ中間の値がある: \(row)")
        XCTAssertEqual(px(100, 100)[3], 255)
    }

    func testDefaultPenPointsCoverTheCenter() {
        var m = ClipMask(shape: "pen")
        XCTAssertEqual(m.shape, "pen", "pen は知っている形として通る")
        XCTAssertTrue(m.points.isEmpty, "切り替え前は点を持たない")
        m.ensurePenPoints()
        XCTAssertEqual(m.points, ClipMask.defaultPenPoints)
        XCTAssertTrue(m.hasPenArea)
        XCTAssertTrue(m.penContains(u: 0.5, v: 0.5), "既定の菱形は中心を含む")
        XCTAssertFalse(m.penContains(u: 0.05, v: 0.05))
        let px = masked(m)
        XCTAssertEqual(px(100, 100)[3], 255)
        XCTAssertEqual(px(10, 10)[3], 0)
    }

    func testDegeneratePenHasNoArea() {
        let two = ClipMask(shape: "pen", points: [MaskPoint(x: 0.3, y: 0.3), MaskPoint(x: 0.7, y: 0.7)])
        XCTAssertFalse(two.hasPenArea)
        XCTAssertTrue(two.sampledPolygon().isEmpty)
        XCTAssertFalse(two.penContains(u: 0.5, v: 0.5))
        let px = masked(two)
        XCTAssertEqual(px(100, 100)[3], 0, "点が 3 未満なら全面が外")
        let inv = masked(ClipMask(shape: "pen", invert: true, points: two.points))
        XCTAssertEqual(inv(100, 100)[3], 255, "反転すれば全面が残る")
    }

    func testPointCountIsCappedAndCoordinatesClamped() {
        let many = (0..<100).map { _ in MaskPoint(x: 0.5, y: 0.5) }
        XCTAssertEqual(ClipMask(shape: "pen", points: many).points.count, ClipMask.maxPoints)
        let p = MaskPoint(x: 3, y: -1, outX: 9, outY: 0.5)
        XCTAssertEqual(p.x, 1); XCTAssertEqual(p.y, 0); XCTAssertEqual(p.outX, 1); XCTAssertEqual(p.outY, 0.5)
        XCTAssertEqual(p.inX, 1, "ハンドルの既定はアンカー(クランプ後)に一致")
        XCTAssertTrue(MaskPoint(x: 0.5, y: 0.5).isCorner)
        XCTAssertFalse(MaskPoint(x: 0.5, y: 0.5, outX: 0.7).isCorner)
    }

    // MARK: 保存/復元

    func testPenRoundTripPreservesPointsAndHandles() throws {
        let m = ClipMask(shape: "pen", feather: 0.2, invert: true, points: [
            MaskPoint(x: 0.2, y: 0.35, outX: 0.5, outY: 0.05),
            MaskPoint(x: 0.8, y: 0.35, inX: 0.5, inY: 0.05),
            MaskPoint(x: 0.8, y: 0.8),
            MaskPoint(x: 0.2, y: 0.8),
        ])
        let json = String(data: try JSONEncoder().encode(m), encoding: .utf8)!
        XCTAssertTrue(json.contains("\"points\""), "ペンは点を書く: \(json)")
        XCTAssertTrue(json.contains("\"outX\""), "アンカーと違うハンドルは書く")
        let back = try JSONDecoder().decode(ClipMask.self, from: Data(json.utf8))
        XCTAssertEqual(back, m, "往復で一致する")
    }

    func testMaskPointOmitsHandlesThatMatchTheAnchor() throws {
        let json = String(data: try JSONEncoder().encode(MaskPoint(x: 0.3, y: 0.4)), encoding: .utf8)!
        XCTAssertFalse(json.contains("inX"), "まっすぐな点はハンドルを書かない: \(json)")
        XCTAssertFalse(json.contains("outX"))
        let back = try JSONDecoder().decode(MaskPoint.self, from: Data(json.utf8))
        XCTAssertEqual(back, MaskPoint(x: 0.3, y: 0.4))
    }

    /// 既存ファイル互換: 点の無い矩形・楕円はそのまま読め、書き戻しても点は増えない。
    func testLegacyShapesWithoutPointsAreUnchanged() throws {
        let legacy = #"{"shape":"ellipse","x":0.1,"y":0.2,"w":0.6,"h":0.4,"feather":0.3}"#
        let m = try JSONDecoder().decode(ClipMask.self, from: Data(legacy.utf8))
        XCTAssertEqual(m.shape, "ellipse")
        XCTAssertTrue(m.points.isEmpty)
        let written = String(data: try JSONEncoder().encode(m), encoding: .utf8)!
        XCTAssertFalse(written.contains("points"), "既存形状の書き方は変えない: \(written)")
        XCTAssertEqual(try JSONDecoder().decode(ClipMask.self, from: Data(written.utf8)), m)

        var c = Clip()
        c.type = .image
        c.mask = ClipMask()
        let clipJSON = String(data: try JSONEncoder().encode(c), encoding: .utf8)!
        XCTAssertFalse(clipJSON.contains("points"), "矩形マスクのクリップにも点は書かない")
        c.mask = square()
        let penClip = try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(penClip.mask, square(), "クリップ経由でも往復一致")
    }

    /// 知らないキーは、点があっても保持して書き戻す(前方互換)。
    func testUnknownKeysSurviveAlongsidePoints() throws {
        let json = #"{"shape":"pen","x":0.25,"y":0.25,"w":0.5,"h":0.5,"points":[{"x":0.25,"y":0.25},{"x":0.75,"y":0.25},{"x":0.5,"y":0.75}],"futureKey":42}"#
        let m = try JSONDecoder().decode(ClipMask.self, from: Data(json.utf8))
        XCTAssertEqual(m.points.count, 3)
        let written = String(data: try JSONEncoder().encode(m), encoding: .utf8)!
        XCTAssertTrue(written.contains("\"futureKey\""), "知らないキーを保持する: \(written)")
        XCTAssertEqual(try JSONDecoder().decode(ClipMask.self, from: Data(written.utf8)), m)
    }

    /// 描画の入口: 画像クリップにペンマスクをかけると、外は背景の色になる。
    func testRendererAppliesPenMask() throws {
        let dir = NSTemporaryDirectory() + "penmask-\(UUID().uuidString)"
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
        p.bg = "#0000ff"
        var c = Clip()
        c.id = "img"; c.type = .image; c.start = 0; c.duration = 2; c.src = path
        var m = ClipMask(shape: "pen")
        m.ensurePenPoints()
        c.mask = m
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
        XCTAssertGreaterThan(at(0.5, 0.5)[0], 200, "菱形の中心は赤(残る)")
        XCTAssertLessThan(at(0.5, 0.5)[2], 60)
        XCTAssertGreaterThan(at(0.05, 0.05)[2], 200, "菱形の外は背景の青")
        XCTAssertLessThan(at(0.05, 0.05)[0], 60)
    }
}
