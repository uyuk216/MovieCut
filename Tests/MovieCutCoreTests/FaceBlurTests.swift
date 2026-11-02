import XCTest
import CoreGraphics
import CoreImage
@testable import MovieCutCore

/// 顔ぼかし: 枠の計算・画素の変化(枠の中だけ)・検出の再利用・見つからないときの扱い。検出は偽物を差し込む(本物の顔は合成画像に無いため)。
final class FaceBlurTests: XCTestCase {
    struct FakeFaces: FaceDetecting {
        let rects: [CGRect]
        func faces(in image: CGImage) -> [CGRect] { rects }
    }

    final class CountingFaces: FaceDetecting, @unchecked Sendable {
        var calls = 0
        let rects: [CGRect]
        init(_ rects: [CGRect]) { self.rects = rects }
        func faces(in image: CGImage) -> [CGRect] { calls += 1; return rects }
    }

    /// なめらかな色 + 細かい格子(モザイク・ぼかしで必ず変わる絵)。不透明。
    func textured(_ w: Int, _ h: Int) -> CGImage {
        let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        c.fill(CGRect(x: 0, y: 0, width: w, height: h))
        c.setFillColor(CGColor(srgbRed: 0.9, green: 0.7, blue: 0.2, alpha: 1))
        var x = 0
        while x < w { c.fill(CGRect(x: x, y: 0, width: 3, height: h)); x += 6 }
        c.setFillColor(CGColor(srgbRed: 0.1, green: 0.1, blue: 0.1, alpha: 1))
        var y = 0
        while y < h { c.fill(CGRect(x: 0, y: y, width: w, height: 2)); y += 5 }
        return c.makeImage()!
    }

    /// 画素を RGBA で読む(上の行が 0)。
    func rgba(_ img: CGImage) -> [UInt8] {
        var d = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let c = CGContext(data: &d, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return d
    }

    func render(_ img: CIImage) -> CGImage { EffectPipeline.makeImage(img, from: img.extent)! }

    /// 検出枠(0〜1・左上原点)の顔 1 つ。
    let face = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)

    // MARK: 枠の計算

    func testPixelRectsPadsAndFlipsToBottomLeftOrigin() {
        let r = FaceBlur.pixelRects([face], in: CGRect(x: 0, y: 0, width: 1000, height: 500))
        XCTAssertEqual(r.count, 1)
        // 余白は各辺 0.125(幅・高さの 25%)。左上原点 → 左下原点で y は (1 − 0.875) × 500 = 62.5
        XCTAssertEqual(r[0].minX, 125, accuracy: 1e-6)
        XCTAssertEqual(r[0].width, 750, accuracy: 1e-6)
        XCTAssertEqual(r[0].minY, 62.5, accuracy: 1e-6)
        XCTAssertEqual(r[0].height, 375, accuracy: 1e-6)
    }

    func testPixelRectsClipsToImageAndDropsEmpty() {
        let r = FaceBlur.pixelRects([CGRect(x: -0.5, y: -0.5, width: 0.6, height: 0.6), CGRect(x: 0.2, y: 0.2, width: 0, height: 0.3)],
                                    in: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(r.count, 1, "幅 0 の枠は捨てる")
        XCTAssertTrue(CGRect(x: 0, y: 0, width: 100, height: 100).contains(r[0]))
    }

    // MARK: 画素(枠の中だけ変わる)

    func assertOnlyInsideChanged(mode: FaceBlur.Mode, minChangedInside: Double, file: StaticString = #filePath, line: UInt = #line) {
        let w = 200, h = 200
        let src = textured(w, h)
        let faces = FakeFaces(rects: [face])
        let detected = FaceDetectionCache(detector: faces).rects(key: "k", image: src)
        let out = rgba(render(FaceBlur.apply(CIImage(cgImage: src), faces: detected, mode: mode, strength: 0.6, scale: 1)))
        let before = rgba(src)
        // 検出枠を余白つきで求めた範囲(上の行が 0 の画素座標)。内側 = 25..<175、外側は 3px 以上離れた所
        var inChanged = 0, inTotal = 0, outMaxDiff = 0
        for y in 0..<h { for x in 0..<w {
            let i = (y * w + x) * 4
            let d = (0..<3).map { abs(Int(out[i + $0]) - Int(before[i + $0])) }.max()!
            let inside = (25..<175).contains(x) && (25..<175).contains(y)
            let far = x < 22 || x >= 178 || y < 22 || y >= 178
            if inside { inTotal += 1; if d > 3 { inChanged += 1 } }
            if far { outMaxDiff = max(outMaxDiff, d) }
        } }
        XCTAssertGreaterThan(Double(inChanged) / Double(inTotal), minChangedInside, "枠の中が変わっていない(\(mode))", file: file, line: line)
        XCTAssertEqual(outMaxDiff, 0, "枠の外が変わった(\(mode))", file: file, line: line)
    }

    /// モザイクは、ブロックの平均と同じ色の画素(単色の所)は変わらないので、枠の中の半分以上が変わることを見る。
    func testMosaicChangesInsideRectOnlyAndKeepsOutsideExact() {
        assertOnlyInsideChanged(mode: .mosaic, minChangedInside: 0.5)
    }

    func testBlurChangesInsideRectOnlyAndKeepsOutsideExact() {
        assertOnlyInsideChanged(mode: .blur, minChangedInside: 0.8)
    }

    func testModeFromParamValue() {
        XCTAssertEqual(FaceBlur.Mode(0), .mosaic)
        XCTAssertEqual(FaceBlur.Mode(0.4), .mosaic)
        XCTAssertEqual(FaceBlur.Mode(1), .blur)
    }

    // MARK: 見つからないとき・強さ 0

    func testNoFacesMeansNoChange() {
        let src = textured(120, 90)
        let out = rgba(render(FaceBlur.apply(CIImage(cgImage: src), faces: [], mode: .mosaic, strength: 0.6, scale: 1)))
        XCTAssertEqual(out, rgba(src))
    }

    func testZeroStrengthMeansNoChange() {
        let src = textured(120, 90)
        let out = rgba(render(FaceBlur.apply(CIImage(cgImage: src), faces: [face], mode: .blur, strength: 0, scale: 1)))
        XCTAssertEqual(out, rgba(src))
    }

    func testVisionFindsNothingOnSyntheticImageAndDoesNotCrash() {
        XCTAssertEqual(VisionFaceDetector().faces(in: textured(640, 360)), [])
    }

    func testEffectPipelineWithoutFacesIsIdentityForFaceBlur() {
        let src = textured(120, 90)
        let fx = [ResolvedEffect(kind: .faceBlur, values: ["strength": 0.6, "mode": 0], color: "#000000")]
        let out = rgba(render(EffectPipeline.apply(CIImage(cgImage: src), effects: fx, bounds: CGRect(x: 0, y: 0, width: 120, height: 90), scale: 1)))
        XCTAssertEqual(out, rgba(src))
    }

    func testEffectPipelineUsesFacesAndResolveDropsZeroStrength() {
        var c = Clip()
        c.effects = [Effect(kind: EffectKind.faceBlur.rawValue, params: ["strength": 0, "mode": 0])]
        XCTAssertTrue(EffectPipeline.resolve(c, atClipTime: 0).isEmpty, "強さ 0 は何もしないので外す")
        c.effects = [Effect(.faceBlur)]
        let fx = EffectPipeline.resolve(c, atClipTime: 0)
        XCTAssertEqual(fx.count, 1)
        let src = textured(200, 200)
        let out = rgba(render(EffectPipeline.apply(CIImage(cgImage: src), effects: fx, bounds: CGRect(x: 0, y: 0, width: 200, height: 200), scale: 1, faces: [face])))
        XCTAssertNotEqual(out, rgba(src))
    }

    // MARK: 検出の再利用

    func testCacheDetectsOncePerKey() {
        let d = CountingFaces([face])
        let cache = FaceDetectionCache(detector: d)
        let img = textured(64, 64)
        _ = cache.rects(key: "clip|1000", image: img)
        _ = cache.rects(key: "clip|1000", image: img)
        XCTAssertEqual(d.calls, 1)
        _ = cache.rects(key: "clip|1033", image: img)
        XCTAssertEqual(d.calls, 2)
        XCTAssertEqual(cache.count, 2)
    }

    // MARK: 1080p の計測(偽の検出器。Vision の時間は含まない)

    func testTimingAt1080p() {
        let src = textured(1920, 1080)
        let ci = CIImage(cgImage: src)
        let fx = [ResolvedEffect(kind: .faceBlur, values: ["strength": 0.6, "mode": 0], color: "#000000")]
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let faces = [CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.3)]
        let cache = FaceDetectionCache(detector: FakeFaces(rects: faces))
        func ms(_ n: Int, _ body: () -> Void) -> Double {
            body()
            let t0 = CFAbsoluteTimeGetCurrent()
            for _ in 0..<n { body() }
            return (CFAbsoluteTimeGetCurrent() - t0) * 1000 / Double(n)
        }
        let mosaic = ms(10) { _ = EffectPipeline.makeImage(EffectPipeline.apply(ci, effects: fx, bounds: bounds, scale: 1, faces: faces), from: bounds) }
        let blurFx = [ResolvedEffect(kind: .faceBlur, values: ["strength": 0.6, "mode": 1], color: "#000000")]
        let blur = ms(10) { _ = EffectPipeline.makeImage(EffectPipeline.apply(ci, effects: blurFx, bounds: bounds, scale: 1, faces: faces), from: bounds) }
        let none = ms(10) { _ = EffectPipeline.makeImage(EffectPipeline.apply(ci, effects: [], bounds: bounds, scale: 1), from: bounds) }
        let hit = ms(50) { _ = cache.rects(key: "t|0", image: src) }
        print("FACEBLUR_TIMING 1080p ms/frame: none=\(String(format: "%.2f", none)) mosaic=\(String(format: "%.2f", mosaic)) blur=\(String(format: "%.2f", blur)) cacheHit=\(String(format: "%.4f", hit))")
        XCTAssertLessThan(mosaic, 1000)
    }
}

extension FaceBlurTests {
    /// モザイクの大きさ(size)が強さより優先される。size が無い古い設定は、強さから決めた大きさのまま。
    func testMosaicSizeOverridesStrengthOnlyWhenPresent() {
        let src = textured(64, 64)
        let f = [CGRect(x: 0, y: 0, width: 1, height: 1)]
        let a = rgba(render(FaceBlur.apply(CIImage(cgImage: src), faces: f, mode: .mosaic, strength: 0.6, scale: 1)))
        let b = rgba(render(FaceBlur.apply(CIImage(cgImage: src), faces: f, mode: .mosaic, strength: 0.6, scale: 1, blockPx: 2)))
        XCTAssertNotEqual(a, b)
        let c = rgba(render(FaceBlur.apply(CIImage(cgImage: src), faces: f, mode: .mosaic, strength: 0.6, scale: 1, blockPx: nil)))
        XCTAssertEqual(a, c)
    }
}
