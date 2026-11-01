import XCTest
import CoreGraphics
@testable import MovieCutCore

/// 図形(クリップの種類 shape): 形の path、画素での見た目、不透明度の二重がけが無いこと、回転、キーフレーム、ファイルの書き方。
final class ShapeTests: XCTestCase {
    // 400×200 のキャンバス、背景は黒
    static let W = 400, H = 200

    func project(clips: [Clip]) -> Project {
        var p = Project()
        p.width = Self.W; p.height = Self.H; p.bg = "#000000"
        var tr = Track(name: "L1"); tr.clips = clips
        p.tracks = [tr]
        return p
    }

    /// 時刻 0 から 1 秒の図形。中心・大きさ・見た目を指定する。
    func shape(_ kind: FigureKind? = nil, x: Double = 0.5, y: Double = 0.5, w: Double = 0.5, h: Double = 0.5,
               fill: String? = nil, stroke: String? = nil, strokeWidth: Double? = nil, corner: Double? = nil,
               opacity: Double? = nil, rotation: Double? = nil) -> Clip {
        var c = Clip()
        c.id = "s"; c.type = .shape; c.start = 0; c.duration = 1
        c.x = x; c.y = y; c.w = w; c.h = h
        c.opacity = opacity; c.rotation = rotation
        c.figure = Figure(kind: kind?.rawValue, fill: fill, stroke: stroke, strokeWidth: strokeWidth, corner: corner).normalized
        return c
    }

    /// 画素(RGBA、左上原点)
    struct Pixels {
        let w: Int, h: Int
        var d: [UInt8]
        func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let i = (y * w + x) * 4
            return (Int(d[i]), Int(d[i + 1]), Int(d[i + 2]))
        }
    }

    func rgbEq(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Bool { a.0 == b.0 && a.1 == b.1 && a.2 == b.2 }

    func render(_ p: Project, t: Double = 0.5) throws -> Pixels {
        let img = try XCTUnwrap(Renderer(project: p, assets: RenderAssets()).renderImage(t: t))
        var d = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let c = CGContext(data: &d, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return Pixels(w: img.width, h: img.height, d: d)
    }

    // MARK: 形の path

    func testRectPathBoundsAndRoundedCorner() {
        let r = FigureGeometry.path(kind: .rect, w: 100, h: 60).boundingBoxOfPath
        XCTAssertEqual(r.minX, -50, accuracy: 1e-9); XCTAssertEqual(r.width, 100, accuracy: 1e-9)
        XCTAssertEqual(r.minY, -30, accuracy: 1e-9); XCTAssertEqual(r.height, 60, accuracy: 1e-9)
        // 角丸は短い辺の割合: 角の一画素目は四角より外が空く
        let round = FigureGeometry.path(kind: .rect, w: 100, h: 60, corner: 0.5)
        XCTAssertFalse(round.contains(CGPoint(x: -49, y: -29)), "角丸の角は塗られない")
        XCTAssertTrue(round.contains(CGPoint(x: 0, y: 0)))
    }

    func testEllipseAndStarStayInsideTheBox() {
        let e = FigureGeometry.path(kind: .ellipse, w: 100, h: 40).boundingBoxOfPath
        XCTAssertEqual(e.width, 100, accuracy: 1e-6); XCTAssertEqual(e.height, 40, accuracy: 1e-6)
        let s = FigureGeometry.path(kind: .star, w: 100, h: 100).boundingBoxOfPath
        XCTAssertLessThanOrEqual(s.maxX, 50 + 1e-6); XCTAssertGreaterThanOrEqual(s.minX, -50 - 1e-6)
        XCTAssertLessThanOrEqual(s.maxY, 50 + 1e-6); XCTAssertGreaterThanOrEqual(s.minY, -50 - 1e-6)
        XCTAssertTrue(FigureGeometry.path(kind: .star, w: 100, h: 100).contains(CGPoint(x: 0, y: 0)))
    }

    func testArrowHasShaftAndTwoHeadStrokesAtTheEnd() {
        let p = FigureGeometry.path(kind: .arrow, w: 100, h: 0.0001, headLength: 10)
        // 軸(終点 = 右下)と、終点から戻る二本の辺。終点の近くは線の上
        let end = CGPoint(x: 50, y: 0.0001 / 2)
        XCTAssertEqual(p.boundingBoxOfPath.maxX, end.x, accuracy: 1e-6, "先は右端")
        var segments = 0
        p.applyWithBlock { el in if el.pointee.type == .addLineToPoint { segments += 1 } }
        XCTAssertEqual(segments, 3, "軸 1 本 + 先 2 本")
        // 線は軸だけ
        var lineSegments = 0
        FigureGeometry.path(kind: .line, w: 100, h: 50).applyWithBlock { el in if el.pointee.type == .addLineToPoint { lineSegments += 1 } }
        XCTAssertEqual(lineSegments, 1)
    }

    // MARK: 画素

    func testFilledRectPixelsAndOutsideIsBackground() throws {
        // 中心 (200,100)、幅 200、高さ 100 → x 100..300、y 50..150
        let px = try render(project(clips: [shape(.rect, fill: "#ff0000")]))
        XCTAssertEqual(px.rgb(200, 100).0, 255)
        XCTAssertEqual(px.rgb(200, 100).1, 0)
        XCTAssertTrue(rgbEq(px.rgb(150, 75), (255, 0, 0)))
        XCTAssertTrue(rgbEq(px.rgb(50, 100), (0, 0, 0)), "外は背景")
        XCTAssertTrue(rgbEq(px.rgb(200, 20), (0, 0, 0)), "上の外は背景")
    }

    func testEllipseLeavesBoundingBoxCornersEmpty() throws {
        let px = try render(project(clips: [shape(.ellipse, fill: "#ffffff")]))
        XCTAssertTrue(rgbEq(px.rgb(200, 100), (255, 255, 255)))
        XCTAssertTrue(rgbEq(px.rgb(105, 55), (0, 0, 0)), "箱の角は楕円の外")
    }

    func testStrokeOnlyRectHasBandAndNoFill() throws {
        // 線の太さ 54(1080p の画素)→ 高さ 200 のキャンバスでは 54 × 200 / 1080 = 10 px。外縁 x = 100 を中心に 95..105
        let px = try render(project(clips: [shape(.rect, fill: "none", stroke: "#ffffff", strokeWidth: 54)]))
        XCTAssertTrue(rgbEq(px.rgb(100, 100), (255, 255, 255)), "線の上")
        XCTAssertTrue(rgbEq(px.rgb(150, 100), (0, 0, 0)), "塗りなし")
        XCTAssertTrue(rgbEq(px.rgb(80, 100), (0, 0, 0)), "線の外")
    }

    func testStrokeWidthScalesWithResolution() throws {
        // 同じ 54 でも 1080 の高さなら 54 px。プレビューと書き出しで同じ割合になる
        var p = project(clips: [shape(.rect, fill: "none", stroke: "#ffffff", strokeWidth: 54)])
        p.width = 800; p.height = 400
        let img = try XCTUnwrap(Renderer(project: p, assets: RenderAssets()).renderImage(t: 0.5))
        XCTAssertEqual(img.width, 800)
        // 中心 (400,200)、幅 400 → 左縁 x = 200、高さ 400 の 54 / 1080 × 400 ≈ 20 px の線
        let d = try render(p)
        XCTAssertTrue(rgbEq(d.rgb(200, 200), (255, 255, 255)))
        XCTAssertTrue(rgbEq(d.rgb(190, 200), (255, 255, 255)))
        XCTAssertTrue(rgbEq(d.rgb(170, 200), (0, 0, 0)))
    }

    func testOpacityIsAppliedOnceAcrossFillAndStroke() throws {
        // 白の塗り + 白の線を 50% で: 重なっても 50% 相当(約 128)。二重なら約 191 になる
        let px = try render(project(clips: [shape(.rect, fill: "#ffffff", stroke: "#ffffff", strokeWidth: 54, opacity: 0.5)]))
        let edge = px.rgb(100, 100).0, inside = px.rgb(200, 100).0
        XCTAssertLessThanOrEqual(abs(edge - 128), 4, "線と塗りの重なりで二重にかからない(\(edge))")
        XCTAssertLessThanOrEqual(abs(inside - 128), 4)
    }

    func testRotationTurnsTheBand() throws {
        // 幅 200、高さ 20(横の帯)を 90 度回すと、縦の帯(x 190..210)になる
        let px = try render(project(clips: [shape(.rect, w: 0.5, h: 0.1, fill: "#ffffff", rotation: 90)]))
        XCTAssertEqual(px.rgb(200, 30).0, 255, "回したあとの縦の帯の上")
        XCTAssertEqual(px.rgb(250, 100).0, 0, "帯の外")
    }

    func testLineIsDrawnWithItsColorAndDefaultWidth() throws {
        // 線は既定 8 px(1080p)→ 200 px 高のキャンバスで 8 × 200 / 1080 ≈ 1.5 px。色は線の色
        let px = try render(project(clips: [shape(.line, w: 0.5, h: 0.5, stroke: "#00ff00")]))
        XCTAssertGreaterThan(px.rgb(200, 100).1, 200, "中心は線の上(端の画素は少し薄い)")
        XCTAssertTrue(rgbEq(px.rgb(300, 100), (0, 0, 0)), "線から離れている")
    }

    // MARK: キーフレーム

    func testKeyframedPositionMovesTheShape() throws {
        var c = shape(.rect, x: 0.25, y: 0.5, w: 0.2, h: 0.2, fill: "#ffffff")
        c.keyframes["x"] = [Keyframe(t: 0, v: 0.25), Keyframe(t: 1, v: 0.75)]
        let early = try render(project(clips: [c]), t: 0.05)
        let late = try render(project(clips: [c]), t: 0.95)
        XCTAssertEqual(early.rgb(100, 100).0, 255, "最初は左に")
        XCTAssertEqual(early.rgb(300, 100).0, 0)
        XCTAssertEqual(late.rgb(300, 100).0, 255, "最後は右に")
        XCTAssertEqual(late.rgb(100, 100).0, 0)
    }

    func testShapeKeysAreTheTransformAndFigureKeys() {
        let c = shape(.rect)
        XCTAssertEqual(Animation.keys(for: c), ["x", "y", "w", "h", "rotation", "opacity"])
    }

    // MARK: ファイル・既定

    func testDefaultFigureIsNotWrittenAndNonDefaultIs() throws {
        let enc = JSONEncoder()
        // 四角形・既定の塗り: figure を書かない
        var plain = ClipEditing.makeShapeClip(.rect, at: 0, project: Project())
        plain.id = "a"
        let plainObj = try JSONSerialization.jsonObject(with: enc.encode(plain)) as? [String: Any]
        XCTAssertNil(plainObj?["figure"])
        XCTAssertEqual(plainObj?["type"] as? String, "shape")
        // 楕円は種類だけ書く
        let ell = ClipEditing.makeShapeClip(.ellipse, at: 0, project: Project())
        let ellObj = try JSONSerialization.jsonObject(with: enc.encode(ell)) as? [String: Any]
        XCTAssertEqual((ellObj?["figure"] as? [String: Any])?["kind"] as? String, "ellipse")
        XCTAssertNil((ellObj?["figure"] as? [String: Any])?["fill"])
    }

    func testFigureRoundTripKeepsValuesAndDropsDefaults() throws {
        let dec = JSONDecoder()
        let f = Figure(kind: "arrow", fill: "none", stroke: "#ff0000", strokeWidth: 12, corner: nil)
        let data = try JSONEncoder().encode(f)
        XCTAssertEqual(try dec.decode(Figure.self, from: data), f)
        XCTAssertNil(Figure(kind: "rect", fill: "#FFFFFF", stroke: "none", strokeWidth: 0, corner: 0).normalized, "全部既定なら何も書かない")
        XCTAssertEqual(Figure(kind: "arrow", strokeWidth: 8).normalized, Figure(kind: "arrow"), "線・矢印の既定の太さ 8 は書かない(種類は残る)")
        XCTAssertEqual(Figure(kind: "line", strokeWidth: 0).normalized?.strokeWidth, 0, "線を消すのは既定と違う")
    }

    func testUnknownKindFallsBackToRectAndBadNumbersToDefaults() {
        let f = Figure(kind: "hexagon", fill: nil, stroke: nil, strokeWidth: .nan, corner: 9)
        XCTAssertEqual(f.figureKind, .rect)
        XCTAssertEqual(f.strokeWidthOrDefault, 0)
        XCTAssertEqual(f.cornerOrDefault, 0.5)
    }

    func testOldProjectWithoutFigureLoadsAsAnEmptyFigure() throws {
        let json = #"{"id":"s","type":"shape","start":0,"duration":2,"x":0.5,"y":0.5,"w":0.3,"h":0.3}"#
        let c = try JSONDecoder().decode(Clip.self, from: Data(json.utf8))
        XCTAssertNil(c.figure)
        XCTAssertEqual(c.figureOrDefault.figureKind, .rect)
        XCTAssertTrue(c.extra.isEmpty, "読めた項目は extra に残らない")
    }

    /// 1080p で図形 5 個の 1 コマの描画時間(参考値。性能の保証ではない)。
    func testBenchmarkOneFrame1080p() throws {
        var p = Project()
        p.width = 1920; p.height = 1080
        var tr = Track(name: "L1")
        for (i, k) in FigureKind.allCases.enumerated() {
            var c = shape(k, x: 0.2 + 0.15 * Double(i), y: 0.5, w: 0.12, h: 0.2, fill: "#ffcc00", stroke: "#000000", strokeWidth: 6, opacity: 0.8)
            c.id = "b\(i)"
            tr.clips.append(c)
        }
        p.tracks = [tr]
        let r = Renderer(project: p, assets: RenderAssets())
        _ = r.renderImage(t: 0.5)
        let n = 20
        let t0 = CFAbsoluteTimeGetCurrent()
        for _ in 0..<n { _ = r.renderImage(t: 0.5) }
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000 / Double(n)
        print("[bench] shape x5 1080p: \(String(format: "%.2f", ms)) ms/frame")
        XCTAssertLessThan(ms, 200, "極端に遅くないこと")
    }
}
