import XCTest
import CoreGraphics
import ImageIO
@testable import MovieCutCore

/// 偽の検出器: 画像の中身によらず、決めた矩形を返す(本物の Vision の代わり)。
struct FixedDetector: SubjectDetecting {
    let rects: [CGRect]
    func subjects(in image: CGImage) -> [CGRect] { rects }
}

final class AutoReframeTests: XCTestCase {
    private let w0 = 1920.0, h0 = 1080.0      // 横長 16:9
    private let W = 1080.0, H = 1920.0        // 縦 9:16

    /// 0〜duration 秒を 5/s で並べた検出(矩形は中心 `x(t)` の小さな四角)。
    private func samples(duration: Double, x: (Double) -> Double) -> [SubjectSample] {
        let n = Int(duration * AutoReframe.sampleRate) + 1
        return (0..<n).map { k in
            let t = Double(k) / AutoReframe.sampleRate
            return SubjectSample(t: t, rects: [CGRect(x: x(t) - 0.05, y: 0.4, width: 0.1, height: 0.2)])
        }
    }

    /// 窓の中心(素材の幅の割合)を、横位置 x から戻す(`AutoReframe.plan` の逆)。
    private func windowCenter(fromX x: Double, scale: Double) -> Double {
        let picWidthCanvas = (H / h0) * w0           // 絵の幅(px・キャンバス上)
        let left = x * W - picWidthCanvas / 2        // 絵の左端(キャンバス px)
        return (W / 2 - left) / picWidthCanvas
    }

    func testCropFollowsMovingSubjectAndStaysInside() throws {
        // 10 秒で左 0.2 → 右 0.8 へ動く被写体
        let s = samples(duration: 10) { 0.2 + 0.6 * $0 / 10 }
        let plan = try XCTUnwrap(AutoReframe.plan(samples: s, sourceWidth: w0, sourceHeight: h0))
        XCTAssertEqual(plan.windowWidth, (W / H) / (w0 / h0), accuracy: 1e-9)
        let half = plan.windowWidth / 2
        for (i, sample) in s.enumerated() {
            let c = plan.centers[i]
            XCTAssertGreaterThanOrEqual(c, half - 1e-9)
            XCTAssertLessThanOrEqual(c, 1 - half + 1e-9)
            // 被写体は窓の中に入っている(端では窓が素材の縁で止まる)
            let subjectX = AutoReframe.focusX(sample.rects) ?? 0.5
            XCTAssertLessThanOrEqual(abs(subjectX - c), half + 1e-6, "t=\(sample.t)")
        }
        // 追従: 中心は前から後ろへ単調に動く
        for i in 1..<plan.centers.count { XCTAssertGreaterThanOrEqual(plan.centers[i], plan.centers[i - 1] - 1e-9) }
        XCTAssertGreaterThan(plan.centers.last! - plan.centers.first!, 0.5)
    }

    func testKeysMapToWindowCenterAndCoverCanvas() throws {
        let s = samples(duration: 4) { $0 < 2 ? 0.05 : 0.95 }   // 端から端へ飛ぶ
        let plan = try XCTUnwrap(AutoReframe.plan(samples: s, sourceWidth: w0, sourceHeight: h0))
        let picCanvas = (H / h0) * w0
        for (k, key) in plan.keys.enumerated() {
            // 絵は縦いっぱいで、キャンバスの左右の縁を覆う(空きが出ない)
            let left = key.v * W - picCanvas / 2
            XCTAssertLessThanOrEqual(left, 1e-6)
            XCTAssertGreaterThanOrEqual(left + picCanvas, W - 1e-6)
            // 画面の中央に見えるのは、計画の窓の中心
            XCTAssertEqual(windowCenter(fromX: key.v, scale: plan.scale), plan.centers[k], accuracy: 1e-9)
        }
        XCTAssertEqual(plan.scale, H / h0 / (W / w0), accuracy: 1e-9)   // 高さを合わせる拡大 ≒ 3.16
    }

    func testSmoothingReducesJitter() throws {
        // 揺れる被写体(決まった擬似乱数の振動)
        let s = samples(duration: 12) { t in 0.5 + 0.12 * sin(t * 7.3) * cos(t * 2.1) + 0.04 * sin(t * 19.0) }
        let raw = s.map { AutoReframe.focusX($0.rects) ?? 0.5 }
        let plan = try XCTUnwrap(AutoReframe.plan(samples: s, sourceWidth: w0, sourceHeight: h0))
        func jitter(_ v: [Double]) -> Double {
            guard v.count > 2 else { return 0 }
            var sum = 0.0
            for i in 2..<v.count { sum += abs(v[i] - 2 * v[i - 1] + v[i - 2]) }
            return sum / Double(v.count - 2)
        }
        let rawJ = jitter(raw), smoothJ = jitter(plan.centers)
        XCTAssertGreaterThan(rawJ, 0)
        XCTAssertLessThan(smoothJ, rawJ * 0.5, "raw=\(rawJ) smoothed=\(smoothJ)")
    }

    func testWideOrPortraitSourceGivesNoPlan() {
        let s = samples(duration: 1) { _ in 0.5 }
        XCTAssertNil(AutoReframe.plan(samples: s, sourceWidth: 1080, sourceHeight: 1920))   // 縦の素材
        XCTAssertNil(AutoReframe.plan(samples: s, sourceWidth: 1080, sourceHeight: 1920 * 1.0))   // 同じ比(9:16)
        XCTAssertNil(AutoReframe.plan(samples: [], sourceWidth: w0, sourceHeight: h0))
    }

    func testApplyWritesScaleAndXKeysAndClearsOldTransform() throws {
        let s = samples(duration: 2) { _ in 0.5 }
        let plan = try XCTUnwrap(AutoReframe.plan(samples: s, sourceWidth: w0, sourceHeight: h0))
        var c = Clip()
        c.type = .video
        c.duration = 2
        c.x = 0.3; c.y = 0.7; c.scale = 2
        c.keyframes = ["scale": [Keyframe(t: 0, v: 1), Keyframe(t: 1, v: 2)], "opacity": [Keyframe(t: 0, v: 1)]]
        AutoReframe.apply(plan, to: &c)
        XCTAssertNil(c.x)
        XCTAssertNil(c.y)
        XCTAssertEqual(c.scale ?? 1, plan.scale, accuracy: 1e-9)
        XCTAssertNil(c.keyframes["scale"])
        XCTAssertEqual(c.keyframes["x"]?.count, s.count)
        XCTAssertNotNil(c.keyframes["opacity"], "関係ない項目は残す")
    }

    /// 実際の描画の入口(`Renderer.reframeSamples`)を、偽の検出器で通す。画像 1 枚を検出し、全部の時刻に使う。
    func testReframeSamplesUsesDetectorOnceForStillImage() throws {
        let dir = NSTemporaryDirectory() + "autoreframe-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/still.png"
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 320, height: 180, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(ctx.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))

        var c = Clip()
        c.type = .image
        c.src = path
        c.duration = 1
        let renderer = Renderer(project: Project(), assets: RenderAssets())
        let got = try XCTUnwrap(renderer.reframeSamples(of: c, detector: FixedDetector(rects: [CGRect(x: 0.6, y: 0.4, width: 0.1, height: 0.2)])))
        XCTAssertEqual(got.w, 320)
        XCTAssertEqual(got.h, 180)
        XCTAssertEqual(got.list.count, Int(1 * AutoReframe.sampleRate) + 1)
        XCTAssertTrue(got.list.allSatisfy { $0.rects.count == 1 && abs($0.rects[0].midX - 0.65) < 1e-9 })
    }
}
