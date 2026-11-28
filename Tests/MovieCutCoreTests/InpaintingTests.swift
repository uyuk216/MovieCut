import XCTest
import CoreGraphics
import CoreImage
@testable import MovieCutCore

/// 物体除去(古典的インペインティング): 一様背景への収束、グラデーションの連続性、
/// 穴の外が 1 画素も変わらないこと、決定性、Renderer 経路(オブジェクトマスクの除去モード)。
final class InpaintingTests: XCTestCase {
    private let W = 64, H = 64

    private func holeRect(_ r: CGRect) -> [Bool] {
        (0..<(W * H)).map { r.contains(CGPoint(x: Double($0 % W) + 0.5, y: Double($0 / W) + 0.5)) }
    }

    /// 背景(`bg(x, y)` の RGB)に、穴の位置へ赤い物を置いた RGBA。
    private func image(hole: [Bool], bg: (Int, Int) -> (UInt8, UInt8, UInt8)) -> [UInt8] {
        var px = [UInt8](repeating: 255, count: W * H * 4)
        for y in 0..<H { for x in 0..<W {
            let i = (y * W + x) * 4
            let c = hole[y * W + x] ? (UInt8(255), UInt8(0), UInt8(0)) : bg(x, y)
            px[i] = c.0; px[i + 1] = c.1; px[i + 2] = c.2
        } }
        return px
    }

    func testUniformBackgroundIsRestored() {
        let hole = holeRect(CGRect(x: 20, y: 20, width: 24, height: 24))
        var px = image(hole: hole) { _, _ in (40, 120, 200) }
        Inpainting.fill(rgba: &px, width: W, height: H, hole: hole)
        for i in 0..<(W * H) where hole[i] {
            XCTAssertEqual(Int(px[i * 4]), 40, accuracy: 1)
            XCTAssertEqual(Int(px[i * 4 + 1]), 120, accuracy: 1)
            XCTAssertEqual(Int(px[i * 4 + 2]), 200, accuracy: 1)
        }
    }

    func testLinearGradientStaysContinuous() {
        // 横方向に 0→252 の線形グラデーション。穴の中も元の傾きに近い値で埋まる
        let hole = holeRect(CGRect(x: 20, y: 20, width: 24, height: 24))
        let bg: (Int, Int) -> (UInt8, UInt8, UInt8) = { x, _ in (UInt8(x * 4), UInt8(x * 4), UInt8(x * 4)) }
        var px = image(hole: hole, bg: bg)
        Inpainting.fill(rgba: &px, width: W, height: H, hole: hole, relaxIterations: 400)
        var worst = 0
        for i in 0..<(W * H) where hole[i] { worst = max(worst, abs(Int(px[i * 4]) - (i % W) * 4)) }
        XCTAssertLessThanOrEqual(worst, 8, "穴の中が元のグラデーションから大きく外れない(最大誤差 \(worst))")
        // 横に隣り合う画素の差が滑らか(段差が無い)
        for y in 24..<40 { for x in 22..<42 {
            let d = abs(Int(px[(y * W + x + 1) * 4]) - Int(px[(y * W + x) * 4]))
            XCTAssertLessThanOrEqual(d, 10, "段差なし (\(x),\(y))")
        } }
    }

    func testOutsideHoleIsUntouchedAndDeterministic() {
        let hole = holeRect(CGRect(x: 10, y: 30, width: 30, height: 20))
        let bg: (Int, Int) -> (UInt8, UInt8, UInt8) = { x, y in (UInt8((x * 7 + y * 3) % 256), UInt8((x * 5) % 256), UInt8((y * 11) % 256)) }
        let original = image(hole: hole, bg: bg)
        var a = original, b = original
        Inpainting.fill(rgba: &a, width: W, height: H, hole: hole)
        Inpainting.fill(rgba: &b, width: W, height: H, hole: hole)
        XCTAssertEqual(a, b, "同じ入力は同じ出力")
        for i in 0..<(W * H) where !hole[i] {
            XCTAssertEqual(Array(a[i * 4..<i * 4 + 4]), Array(original[i * 4..<i * 4 + 4]), "穴の外は 1 画素も変わらない")
        }
        XCTAssertNotEqual(a, original, "穴の中は変わっている")
    }

    func testDegenerateInputs() {
        var px = [UInt8](repeating: 9, count: W * H * 4)
        let all = [Bool](repeating: true, count: W * H)
        Inpainting.fill(rgba: &px, width: W, height: H, hole: all)
        XCTAssertTrue(px.allSatisfy { $0 == 9 }, "全面が穴なら何もしない")
        var tiny = [UInt8](repeating: 0, count: 3)
        Inpainting.fill(rgba: &tiny, width: W, height: H, hole: all)   // 大きさ不一致でも落ちない
    }

    // MARK: Renderer 経路

    /// 200×200 の青地に赤い四角(中央)を描いたクリップ画像へ、除去モードのオブジェクトマスクをかける。
    private func removed(full: Bool, removal: Bool = true) throws -> (Int, Int) -> [Int] {
        let size = 200
        let ctx = try XCTUnwrap(CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 70, y: 70, width: 60, height: 60))
        let src = CIImage(cgImage: try XCTUnwrap(ctx.makeImage()))
        let rect = TrackRect(x: 0.3, y: 0.3, w: 0.4, h: 0.4)   // 赤い四角(0.35〜0.65)を含む
        let om = ObjectMask(sourceClipId: "s", seedRect: rect, samples: [ObjectMaskSample(t: 0, rect: rect)], removal: removal)
        let out = ObjectMaskRenderer.apply(src, objectMask: om, at: 0, canvasWidth: 200, canvasHeight: 200,
                                           originX: 0, originY: 0, inpaintMaxSide: full ? nil : 64)
        let cg = try XCTUnwrap(EffectPipeline.makeImage(out, from: CGRect(x: 0, y: 0, width: 200, height: 200)))
        var d = [UInt8](repeating: 0, count: size * size * 4)
        let c = CGContext(data: &d, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.translateBy(x: 0, y: CGFloat(size)); c.scaleBy(x: 1, y: -1)
        c.draw(cg, in: CGRect(x: 0, y: 0, width: size, height: size))
        return { x, y in let i = (y * size + x) * 4; return [Int(d[i]), Int(d[i + 1]), Int(d[i + 2]), Int(d[i + 3])] }
    }

    func testRendererRemovalFillsObjectWithBackground() throws {
        for full in [true, false] {
            let px = try removed(full: full)
            let c = px(100, 100)
            XCTAssertLessThan(c[0], 40, "赤い物が消えている(full=\(full)): \(c)")
            XCTAssertGreaterThan(c[2], 200, "背景の青で埋まる(full=\(full)): \(c)")
            XCTAssertEqual(c[3], 255, "透明にはならない")
            XCTAssertEqual(px(5, 5), [0, 0, 255, 255], "対象の外は変わらない")
        }
    }

    func testRendererKeepsObjectWhenRemovalOff() throws {
        let px = try removed(full: true, removal: false)
        XCTAssertGreaterThan(px(100, 100)[0], 200, "除去でなければ対象の中は残る(従来のマスク)")
        XCTAssertEqual(px(5, 5)[3], 0, "従来のマスクの外は透明")
    }

    func testRemovalRoundTripAndDefaultOmitted() throws {
        let rect = TrackRect(x: 0.3, y: 0.3, w: 0.4, h: 0.4)
        let on = ObjectMask(sourceClipId: "s", seedRect: rect, samples: [ObjectMaskSample(t: 0, rect: rect)], removal: true)
        XCTAssertEqual(try JSONDecoder().decode(ObjectMask.self, from: JSONEncoder().encode(on)), on)
        let off = ObjectMask(sourceClipId: "s", seedRect: rect)
        XCTAssertFalse(String(data: try JSONEncoder().encode(off), encoding: .utf8)!.contains("removal"))
    }
}
