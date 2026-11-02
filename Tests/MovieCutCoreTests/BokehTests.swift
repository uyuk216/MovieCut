import XCTest
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import MovieCutCore

/// 絞り形のボケ: 形(頂点・ずらし位置)・点光源がその形の円盤になること・エネルギー・ハイライトの強調・エフェクトとぼかし範囲の描画経路・ファイル・速度。
final class BokehTests: XCTestCase {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("bokeh-tests-\(UUID().uuidString)")
    override func setUpWithError() throws { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    // MARK: 形

    func testPolygonsHaveTheRightVerticesAndStartAtTheTop() throws {
        XCTAssertNil(ApertureShape.circle.polygon())
        for (shape, n) in [(ApertureShape.triangle, 3), (.square, 4), (.pentagon, 5), (.hexagon, 6), (.octagon, 8), (.star, 10)] {
            let p = try XCTUnwrap(shape.polygon(), shape.name)
            XCTAssertEqual(p.count, n, shape.name)
            XCTAssertEqual(p.map { hypot($0.x, $0.y) }.max()!, 1, accuracy: 1e-9, "外接円の半径 1: \(shape.name)")
            XCTAssertEqual(p[0].x, 0, accuracy: 1e-9); XCTAssertEqual(p[0].y, 1, accuracy: 1e-9, "最初の頂点は真上: \(shape.name)")
        }
        let heart = try XCTUnwrap(ApertureShape.heart.polygon())
        XCTAssertEqual(heart.map { hypot($0.x, $0.y) }.max()!, 1, accuracy: 1e-9)
        XCTAssertGreaterThan(heart.map(\.y).max()!, 0.3)
    }

    func testRotationTurnsClockwise() throws {
        let tri = try XCTUnwrap(ApertureShape.triangle.polygon(rotation: 90))
        // 真上の頂点が、時計回りに 90° で右(+x)へ来る
        XCTAssertEqual(tri[0].x, 1, accuracy: 1e-9); XCTAssertEqual(tri[0].y, 0, accuracy: 1e-9)
        let same = try XCTUnwrap(ApertureShape.square.polygon(rotation: 360))
        let base = try XCTUnwrap(ApertureShape.square.polygon())
        for (a, b) in zip(same, base) { XCTAssertEqual(a.x, b.x, accuracy: 1e-9); XCTAssertEqual(a.y, b.y, accuracy: 1e-9) }
    }

    func testNamesAndValuesRoundTripAndFallBackToCircle() {
        for s in ApertureShape.allCases {
            XCTAssertEqual(ApertureShape(name: s.name), s)
            XCTAssertEqual(ApertureShape(value: Double(s.rawValue)), s)
            XCTAssertFalse(s.label.isEmpty)
        }
        XCTAssertEqual(ApertureShape(name: nil), .circle)
        XCTAssertEqual(ApertureShape(name: "dodecagon"), .circle, "知らない名前は円")
        XCTAssertEqual(ApertureShape(value: 99), .heart, "範囲外は端へ")
        XCTAssertEqual(ApertureShape(value: -5), .circle)
        XCTAssertEqual(ApertureShape(value: 3.6), .hexagon, "丸める")
        XCTAssertEqual(ApertureShape(value: .nan), .circle)
        XCTAssertEqual(ApertureShape.allCases.map(\.label), ["円", "三角形", "四角形", "五角形", "六角形", "八角形", "星", "ハート"])
    }

    func testOffsetsFillTheShapeEvenlyAndAreCentered() throws {
        for s in ApertureShape.allCases {
            let (pts, d) = Bokeh.offsets(shape: s, radius: 60)
            XCTAssertGreaterThan(pts.count, 20, s.name)
            XCTAssertLessThan(pts.count, 130, s.name)
            XCTAssertGreaterThan(d, 1)
            XCTAssertEqual(pts.map(\.x).reduce(0, +) / Double(pts.count), 0, accuracy: 1e-9, "重心 x \(s.name)")
            XCTAssertEqual(pts.map(\.y).reduce(0, +) / Double(pts.count), 0, accuracy: 1e-9, "重心 y \(s.name)")
            XCTAssertLessThanOrEqual(pts.map { hypot($0.x, $0.y) }.max()!, 60 * 1.1, s.name)
        }
        // 面積に比例した数: 円(π)の点の数は、同じ目標なら四角形(2)でも近い(間隔を面積から決めるため)
        let c = Bokeh.offsets(shape: .circle, radius: 60).points.count, q = Bokeh.offsets(shape: .square, radius: 60).points.count
        XCTAssertEqual(Double(c), Double(q), accuracy: Double(Bokeh.targetSamples) * 0.35)
        // 六角形の点は六角形の内側
        let hexa = try XCTUnwrap(ApertureShape.hexagon.polygon())
        let hp = Bokeh.offsets(shape: .hexagon, radius: 60).points
        let cx = 0.0, _ = cx
        // 重心を引く前の格子から ±(間隔 / 2) の余裕を見る
        let slack = Bokeh.offsets(shape: .hexagon, radius: 60).spacing
        XCTAssertTrue(hp.allSatisfy { Bokeh.inside(CGPoint(x: $0.x / (60 + slack), y: $0.y / (60 + slack)), polygon: hexa) })
    }

    func testTinyOrInvalidRadiusGivesASingleCenterPoint() {
        for r in [0.0, 0.3, -4, .nan, .infinity] {
            let (pts, _) = Bokeh.offsets(shape: .star, radius: r)
            XCTAssertEqual(pts, [.zero], "r=\(r)")
        }
    }

    func testRotationChangesTheSampledShape() {
        let a = Bokeh.offsets(shape: .triangle, radius: 50).points, b = Bokeh.offsets(shape: .triangle, radius: 50, rotation: 90).points
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(Bokeh.offsets(shape: .circle, radius: 50).points.count, Bokeh.offsets(shape: .circle, radius: 50, rotation: 33).points.count, "円は向きに依らない")
    }

    // MARK: 画素

    struct Px {
        let w: Int, h: Int, d: [UInt8]
        func g(_ x: Int, _ y: Int) -> Int { Int(d[(y * w + x) * 4 + 1]) }
        var sum: Int { stride(from: 1, to: d.count, by: 4).reduce(0) { $0 + Int(d[$1]) } }
    }

    func px(_ ci: CIImage, _ rect: CGRect) throws -> Px {
        let img = try XCTUnwrap(EffectPipeline.makeImage(ci, from: rect))
        var d = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let c = CGContext(data: &d, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return Px(w: img.width, h: img.height, d: d)
    }

    /// 400×400 の黒に、中央へ白い光(半径 12)。ぼかすと薄まるので、8 ビットで測れるだけの大きさにしてある。
    func dotImage(size n: Int = 400, brightness: CGFloat = 1) -> CIImage {
        let c = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(gray: 0, alpha: 1); c.fill(CGRect(x: 0, y: 0, width: n, height: n))
        c.setFillColor(gray: brightness, alpha: 1); c.fillEllipse(in: CGRect(x: n / 2 - 12, y: n / 2 - 12, width: 24, height: 24))
        return CIImage(cgImage: c.makeImage()!)
    }

    let all400 = CGRect(x: 0, y: 0, width: 400, height: 400)

    /// 中心から (dx, dy)(上下左右の 1 方向)へ進んで、中心の明るさ(5×5 の平均)の半分を切る距離。
    func reach(_ p: Px, dx: Int, dy: Int) -> Double {
        let cx = p.w / 2, cy = p.h / 2
        var c = 0
        for y in -2...2 { for x in -2...2 { c += p.g(cx + x, cy + y) } }
        let center = Double(c) / 25
        var r = 0
        while r < p.w / 2 - 3, Double(p.g(cx + dx * r, cy + dy * r)) > center * 0.5 { r += 1 }
        return Double(r)
    }

    func testPointLightBecomesADiscOfTheChosenShape() throws {
        let src = dotImage()
        let R = 50.0
        let circle = try px(Bokeh.apply(src, radius: R, shape: .circle, highlight: 0), all400)
        let hex = try px(Bokeh.apply(src, radius: R, shape: .hexagon, highlight: 0), all400)
        XCTAssertGreaterThan(circle.g(200, 200), 8, "点が円盤に広がる(見えるだけの明るさがある)")
        // 円: 上下左右どの向きでも、半径はほぼ R
        for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
            XCTAssertEqual(reach(circle, dx: dx, dy: dy), R, accuracy: R * 0.12, "円 (\(dx),\(dy))")
        }
        XCTAssertEqual(circle.g(200 + Int(1.25 * R), 200), 0, accuracy: 1)
        // 六角形(頂点が真上と真下): 縦は頂点(R)、横は辺(√3/2 R ≈ 0.866R)
        let up = reach(hex, dx: 0, dy: -1), down = reach(hex, dx: 0, dy: 1), right = reach(hex, dx: 1, dy: 0), left = reach(hex, dx: -1, dy: 0)
        XCTAssertEqual(up, R, accuracy: R * 0.12, "頂点の向き(とがった先は薄く見えるので、少し短く出る)")
        XCTAssertEqual(down, R, accuracy: R * 0.12)
        XCTAssertEqual(right, R * 0.866, accuracy: R * 0.1, "辺の向き")
        XCTAssertEqual(left, R * 0.866, accuracy: R * 0.1)
        XCTAssertGreaterThan(up / right, 1.05, "六角形は縦長(頂点の向きが長い)")
        // 円盤は平ら: 0.7R の所も中心とほぼ同じ明るさ
        XCTAssertEqual(Double(circle.g(200 + Int(0.7 * R), 200)), Double(circle.g(200, 200)), accuracy: Double(circle.g(200, 200)) * 0.25)
    }

    func testShapeIsRotatable() throws {
        let src = dotImage()
        let R = 70.0
        // 星(頂点 5 つ。1 つが真上): 真上は長く、真下は短い。180° 回すと入れ替わる
        let up = try px(Bokeh.apply(src, radius: R, shape: .star, highlight: 0), all400)
        let down = try px(Bokeh.apply(src, radius: R, shape: .star, rotation: 180, highlight: 0), all400)
        XCTAssertGreaterThan(reach(up, dx: 0, dy: -1), reach(up, dx: 0, dy: 1) * 1.3, "星の頂点は真上")
        XCTAssertGreaterThan(reach(down, dx: 0, dy: 1), reach(down, dx: 0, dy: -1) * 1.3, "180° 回すと頂点は真下")
        XCTAssertEqual(reach(up, dx: 0, dy: -1), reach(down, dx: 0, dy: 1), accuracy: 8, "180° 回した星の頂点は、同じ長さで反対側")
        // 三角形(頂点が真上)を 90° 回すと、頂点が真右へ来る
        let tri = try px(Bokeh.apply(src, radius: R, shape: .triangle, highlight: 0), all400)
        let tri90 = try px(Bokeh.apply(src, radius: R, shape: .triangle, rotation: 90, highlight: 0), all400)
        XCTAssertGreaterThan(reach(tri, dx: 0, dy: -1), reach(tri, dx: 1, dy: 0) * 1.3, "頂点は真上")
        XCTAssertGreaterThan(reach(tri90, dx: 1, dy: 0), reach(tri90, dx: -1, dy: 0) * 1.3, "90° 回すと頂点は真右")
    }

    func testEnergyIsConservedWithoutHighlight() throws {
        let plain = dotImage()
        let dotPixels = Double(try px(plain, all400).sum) / 255
        let src = plain
        let expected = dotPixels * 255
        for s in [ApertureShape.circle, .hexagon, .star, .heart] {
            let after = Double(try px(Bokeh.apply(src, radius: 60, shape: s, highlight: 0), all400).sum)
            XCTAssertEqual(after, expected, accuracy: expected * 0.1, s.name)
        }
    }

    func testHighlightBoostBrightensOnlyBrightAreas() throws {
        let bright = dotImage()
        let plain = try px(Bokeh.apply(bright, radius: 50, shape: .circle, highlight: 0), all400).g(200, 200)
        let boosted = try px(Bokeh.apply(bright, radius: 50, shape: .circle, highlight: 1), all400).g(200, 200)
        XCTAssertGreaterThan(boosted, plain + 8, "明るい点は、強調でさらにはっきりした円盤になる")
        // しきい値以下の暗い絵は、強調しても変わらない
        let dark = dotImage(brightness: 0.4)
        let dp = try px(Bokeh.apply(dark, radius: 50, shape: .circle, highlight: 0), all400)
        let db = try px(Bokeh.apply(dark, radius: 50, shape: .circle, highlight: 1), all400)
        XCTAssertEqual(db.g(200, 200), dp.g(200, 200), accuracy: 1)
    }

    func testEdgesAreNotDarkenedAndOutputKeepsTheExtent() throws {
        // 一様な灰色: ぼかしても縁まで同じ色(端を延ばして読むので暗くならない)
        let n = 160
        let c = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(gray: 0.5, alpha: 1); c.fill(CGRect(x: 0, y: 0, width: n, height: n))
        let src = CIImage(cgImage: c.makeImage()!)
        let out = Bokeh.apply(src, radius: 30, shape: .octagon, highlight: 0.5)
        XCTAssertEqual(out.extent, src.extent)
        let p = try px(out, src.extent)
        XCTAssertEqual(p.g(0, 0), p.g(80, 80), accuracy: 2)
        XCTAssertEqual(p.g(n - 1, n - 1), p.g(80, 80), accuracy: 2)
    }

    func testDoesNothingForTinyRadius() {
        let src = dotImage()
        XCTAssertEqual(Bokeh.apply(src, radius: 0, shape: .star).extent, src.extent)
        let a = try? px(Bokeh.apply(src, radius: 0.2, shape: .star), all400), b = try? px(src, all400)
        XCTAssertEqual(a?.d, b?.d)
    }

    // MARK: エフェクト(クリップ)

    /// 黒に白い光(半径 = 一辺の 3%)の PNG。
    func png(_ name: String, size n: Int = 800, light: Double = 0.015) throws -> String {
        let c = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(gray: 0, alpha: 1); c.fill(CGRect(x: 0, y: 0, width: n, height: n))
        let r = Double(n) * light
        c.setFillColor(gray: 1, alpha: 1); c.fillEllipse(in: CGRect(x: Double(n) / 2 - r, y: Double(n) / 2 - r, width: 2 * r, height: 2 * r))
        let url = tmp.appendingPathComponent("\(name)-\(n)-\(light).png")
        let d = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(d, c.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(d))
        return url.path
    }

    /// 一辺 `size` の正方形のキャンバスに、画像を全面に置く(背景は黒)。
    func project(_ path: String, _ effects: [Effect], size: Int = 800) -> Project {
        var c = Clip(); c.id = "i"; c.type = .image; c.src = path; c.start = 0; c.duration = 4; c.x = 0.5; c.y = 0.5; c.scale = 1
        c.effects = effects
        var p = Project(); p.width = size; p.height = size; p.bg = "#000000"; p.characters = []
        var tr = Track(name: "L1"); tr.clips = [c]; p.tracks = [tr]
        return p
    }

    func render(_ p: Project) throws -> Px {
        let img = try XCTUnwrap(Renderer(project: p, assets: RenderAssets()).renderImage(t: 0.5))
        var d = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let c = CGContext(data: &d, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return Px(w: img.width, h: img.height, d: d)
    }

    /// エフェクトの radius は 1080p での大きさ(最大 100)。一辺 800 のキャンバスでは × 0.556 の画素になる(`scale(for:)`)。
    func scale(for size: Int) -> Double { (Double(size * size) / (1920.0 * 1080.0)).squareRoot() }

    func bokehEffect(radius: Double = 90, shape: ApertureShape = .circle, highlight: Double = 0.3, rotation: Double = 0) -> Effect {
        var e = Effect(.bokehBlur)
        e.params = ["radius": radius, "shape": Double(shape.rawValue), "highlight": highlight, "rotation": rotation]
        return e
    }

    func testEffectSpecAndDefaults() {
        XCTAssertEqual(EffectKind.bokehBlur.label, "絞りぼかし")
        XCTAssertEqual(EffectKind.bokehBlur.params.map(\.key), ["radius", "shape", "highlight", "rotation"])
        XCTAssertEqual(EffectKind.bokehBlur.spec("shape")?.unit, .aperture)
        XCTAssertEqual(EffectKind.bokehBlur.spec("shape")?.range, 0...Double(ApertureShape.allCases.count - 1))
        let e = Effect(.bokehBlur)
        XCTAssertEqual(e.value("radius"), 20); XCTAssertEqual(e.value("shape"), 0); XCTAssertEqual(e.value("highlight"), 0.3)
        var zero = Clip(); zero.id = "z"; zero.type = .image; zero.src = "/a.png"; zero.duration = 1
        var z = Effect(.bokehBlur); z.params["radius"] = 0
        zero.effects = [z]
        XCTAssertTrue(EffectPipeline.resolve(zero, atClipTime: 0).isEmpty, "半径 0 は何もしない(速い道)")
        zero.effects = [Effect(.bokehBlur)]
        XCTAssertEqual(EffectPipeline.resolve(zero, atClipTime: 0).count, 1)
    }

    func testRendererShowsTheApertureShapeOnAPointLight() throws {
        let path = try png("pt")
        let c = 400                                                  // 中心(800 の半分)
        let plain = try render(project(path, []))
        let circle = try render(project(path, [bokehEffect(radius: 90, shape: .circle, highlight: 1)]))     // 半径 90 × 0.556 = 50 画素
        let hex = try render(project(path, [bokehEffect(radius: 90, shape: .hexagon, highlight: 1)]))
        XCTAssertEqual(plain.g(c, c), 255)
        XCTAssertGreaterThan(circle.g(c, c), 20, "点が円盤に広がる")
        XCTAssertLessThan(circle.g(c, c), 255)
        XCTAssertNotEqual(circle.d, hex.d, "形で絵が変わる")
        let R = 90 * scale(for: 800)
        XCTAssertEqual(reach(circle, dx: 1, dy: 0), R, accuracy: R * 0.15, "円盤の半径がエフェクトの半径(解像度に合わせた画素)")
        XCTAssertEqual(reach(circle, dx: 0, dy: -1), reach(circle, dx: 1, dy: 0), accuracy: 6, "円は縦横ほぼ同じ")
        // 三角形(頂点が真上): 上が長く下が短い。向きを 180° 回すと入れ替わる
        let tri = try render(project(path, [bokehEffect(radius: 90, shape: .triangle, highlight: 0.3)]))
        let tri180 = try render(project(path, [bokehEffect(radius: 90, shape: .triangle, highlight: 0.3, rotation: 180)]))
        XCTAssertGreaterThan(reach(tri, dx: 0, dy: -1), reach(tri, dx: 0, dy: 1) * 1.3)
        XCTAssertGreaterThan(reach(tri180, dx: 0, dy: 1), reach(tri180, dx: 0, dy: -1) * 1.3)
    }

    func testRadiusScalesWithResolution() throws {
        // 同じ引数(1080p 基準)で一辺 400 と 800 のキャンバス: 円盤の見かけの大きさ(画面に対する割合)が同じ
        let small = try render(project(try png("s", size: 400), [bokehEffect(radius: 100, shape: .circle, highlight: 1)], size: 400))
        let big = try render(project(try png("s", size: 800), [bokehEffect(radius: 100, shape: .circle, highlight: 1)], size: 800))
        XCTAssertGreaterThan(reach(small, dx: 1, dy: 0), 8)
        XCTAssertEqual(reach(big, dx: 1, dy: 0) / Double(big.w), reach(small, dx: 1, dy: 0) / Double(small.w), accuracy: 0.015)
    }

    func testMarginCoversTheRadius() {
        var c = Clip(); c.id = "m"; c.type = .image; c.src = "/a.png"; c.duration = 1
        c.effects = [Effect(.bokehBlur)]
        let fx = EffectPipeline.resolve(c, atClipTime: 0)
        XCTAssertGreaterThanOrEqual(EffectPipeline.margin(of: fx, scale: 1), 20)
        XCTAssertGreaterThanOrEqual(EffectPipeline.margin(of: fx, scale: 2), 40)
    }

    // MARK: ぼかし範囲(背景ぼかし)

    func testBlurRegionBokehModeUsesTheChosenShape() throws {
        // 下の絵: 黒い背景の点光源。その上にぼかし範囲(全面)。強さ 12 → 半径 24 の円盤
        let path = try png("region", size: 200, light: 0.06)
        var img = Clip(); img.id = "i"; img.type = .image; img.src = path; img.start = 0; img.duration = 4; img.x = 0.5; img.y = 0.5; img.scale = 1
        var blur = Clip(); blur.id = "b"; blur.type = .blur; blur.start = 0; blur.duration = 4; blur.x = 0.5; blur.y = 0.5; blur.w = 1; blur.h = 1; blur.strength = 22
        blur.blurMode = "bokeh"
        var p = Project(); p.width = 200; p.height = 200; p.bg = "#000000"; p.characters = []
        var t0 = Track(name: "L0"); t0.clips = [img]
        var t1 = Track(name: "L1"); t1.clips = [blur]
        p.tracks = [t0, t1]
        let circle = try render(p)
        p.tracks[1].clips[0].bokehShape = "triangle"
        let tri = try render(p)
        p.tracks[1].clips[0].blurMode = nil
        let gauss = try render(p)
        XCTAssertGreaterThan(circle.g(100, 100), 8, "点が円盤に広がる")
        XCTAssertEqual(reach(circle, dx: 0, dy: -1), reach(circle, dx: 1, dy: 0), accuracy: 5)
        XCTAssertGreaterThan(reach(tri, dx: 0, dy: -1), reach(tri, dx: 0, dy: 1) * 1.3, "三角形は頂点(上)が長い")
        XCTAssertNotEqual(circle.d, tri.d)
        XCTAssertNotEqual(circle.d, gauss.d, "ふつうのぼかしとは別物")
        XCTAssertGreaterThan(gauss.g(100, 100), 0)
    }

    // MARK: ファイル

    func testFileFormatKeepsDefaultsOutAndRoundTrips() throws {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        var blur = Clip(); blur.id = "b"; blur.type = .blur; blur.start = 0; blur.duration = 1
        let plain = String(decoding: try enc.encode(blur), as: UTF8.self)
        XCTAssertFalse(plain.contains("bokeh"))
        blur.blurMode = "bokeh"
        XCTAssertFalse(String(decoding: try enc.encode(blur), as: UTF8.self).contains("bokehShape"), "円は形を書かない")
        blur.bokehShape = "star"
        let s = String(decoding: try enc.encode(blur), as: UTF8.self)
        XCTAssertTrue(s.contains("\"blurMode\":\"bokeh\"")); XCTAssertTrue(s.contains("\"bokehShape\":\"star\""))
        let back = try JSONDecoder().decode(Clip.self, from: Data(s.utf8))
        XCTAssertEqual(back.bokehShapeOrDefault, .star)
        XCTAssertEqual(String(decoding: try enc.encode(back), as: UTF8.self), s)
        XCTAssertNil(back.extra["bokehShape"])
        // 未知の形の名前は、そのまま残して円として描く
        blur.bokehShape = "dodecagon"
        let u = String(decoding: try enc.encode(blur), as: UTF8.self)
        let ub = try JSONDecoder().decode(Clip.self, from: Data(u.utf8))
        XCTAssertEqual(ub.bokehShape, "dodecagon"); XCTAssertEqual(ub.bokehShapeOrDefault, .circle)
        // エフェクトの往復(引数は他のエフェクトと同じ)
        var c = Clip(); c.id = "i"; c.type = .image; c.src = "/a.png"; c.effects = [Effect(.bokehBlur), Effect(kind: "bokehBlur")]
        let ce = try JSONDecoder().decode(Clip.self, from: try enc.encode(c))
        XCTAssertEqual(ce.effects[0].known, .bokehBlur)
        XCTAssertEqual(ce.effects[0].params["shape"], 0)
        XCTAssertEqual(ce.effects, c.effects)
    }

    func testOldFilesAreUntouched() throws {
        let files = (Bundle.module.urls(forResourcesWithExtension: "ymproj", subdirectory: "Fixtures") ?? [])
            + (Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: "Fixtures") ?? [])
        XCTAssertFalse(files.isEmpty)
        for f in files {
            guard let p = try? Project.load(from: f) else { continue }
            let once = String(decoding: try p.encoded(), as: UTF8.self)
            XCTAssertFalse(once.contains("bokeh"), f.lastPathComponent)
        }
    }

    // MARK: 速さ

    func testCostAt1080p() throws {
        let n = 1920, h = 1080
        let c = CGContext(data: nil, width: n, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(gray: 0.1, alpha: 1); c.fill(CGRect(x: 0, y: 0, width: n, height: h))
        c.setFillColor(gray: 1, alpha: 1)
        for i in 0..<30 { c.fillEllipse(in: CGRect(x: 100 + i * 55, y: 100 + (i * 97) % 800, width: 10, height: 10)) }
        let src = CIImage(cgImage: c.makeImage()!)
        let rect = src.extent
        // createCGImage の結果は読むまで描かれないことがあるので、全画素を読んで描画の時間を測る
        var buffer = [UInt8](repeating: 0, count: n * h * 4)
        // 同じ絵を繰り返すと CoreImage の中間の置き場に当たって実際の時間が測れないので、置き場を使わない CIContext で測る
        let timing = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, .cacheIntermediates: false])
        func render(_ ci: CIImage) -> Bool {
            buffer.withUnsafeMutableBytes { timing.render(ci, toBitmap: $0.baseAddress!, rowBytes: n * 4, bounds: rect, format: .BGRA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) }
            return true
        }
        for (name, r, hl) in [("r=20 円", 20.0, 0.0), ("r=20 円+強調", 20.0, 0.3), ("r=60 六角形+強調", 60.0, 0.3)] {
            let shape: ApertureShape = name.contains("六角形") ? .hexagon : .circle
            _ = render(Bokeh.apply(src, radius: r, shape: shape, highlight: hl))
            let k = 5
            let t0 = CFAbsoluteTimeGetCurrent()
            for _ in 0..<k { XCTAssertTrue(render(Bokeh.apply(src, radius: r, shape: shape, highlight: hl))) }
            print("[Bokeh] 1920x1080 \(name): \(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - t0) * 1000 / Double(k))) ms/frame")
        }
        XCTAssertGreaterThan(buffer.reduce(0) { $0 + Int($1) }, 0)
        let t1 = CFAbsoluteTimeGetCurrent()
        for _ in 0..<5 { _ = render(src.clampedToExtent().applyingGaussianBlur(sigma: 10).cropped(to: rect)) }
        print("[Bokeh] 1920x1080 ガウスぼかし(参考): \(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - t1) * 1000 / 5)) ms/frame")
    }
}




