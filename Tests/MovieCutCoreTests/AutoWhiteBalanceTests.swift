import XCTest
import CoreGraphics
@testable import MovieCutCore

/// 自動ホワイトバランス(グレーワールド)。計算(純粋)と、実際の描画経路で灰色に近づくかを確かめる。
final class AutoWhiteBalanceTests: XCTestCase {
    func lin(_ v: Int) -> Double { Double(v) / 255 }

    // MARK: 決める

    func testNeutralGrayNeedsNoCorrection() {
        let r = AutoWhiteBalance.estimate(r: 0.3, g: 0.3, b: 0.3)
        XCTAssertEqual(r, AutoWhiteBalance.Result(temperature: 0, tint: 0))
        XCTAssertEqual(r?.isNeutral, true)
    }

    func testWarmCastGetsNegativeTemperatureAndCoolCastPositive() throws {
        let warm = try XCTUnwrap(AutoWhiteBalance.estimate(r: 0.5, g: 0.3, b: 0.15))
        XCTAssertLessThan(warm.temperature, -0.3, "赤が多い = 暖かすぎる → 冷たくする")
        let cool = try XCTUnwrap(AutoWhiteBalance.estimate(r: 0.15, g: 0.3, b: 0.5))
        XCTAssertGreaterThan(cool.temperature, 0.2, "青が多い → 暖かくする")
    }

    func testGreenCastGetsPositiveTintAndMagentaNegative() throws {
        let green = try XCTUnwrap(AutoWhiteBalance.estimate(r: 0.2, g: 0.4, b: 0.2))
        XCTAssertGreaterThan(green.tint, 0.3, "緑が多い → ティント + で緑を減らす")
        let magenta = try XCTUnwrap(AutoWhiteBalance.estimate(r: 0.4, g: 0.2, b: 0.4))
        XCTAssertLessThan(magenta.tint, -0.3)
    }

    func testResultIsClampedRoundedAndInvalidInputIsNil() throws {
        let extreme = try XCTUnwrap(AutoWhiteBalance.estimate(r: 1, g: 1, b: 0.001))
        XCTAssertEqual(extreme.temperature, -1)
        XCTAssertEqual((extreme.tint * 100).rounded(), extreme.tint * 100, accuracy: 1e-9, "小数 2 桁")
        XCTAssertNil(AutoWhiteBalance.estimate(r: 0, g: 0.3, b: 0.3))
        XCTAssertNil(AutoWhiteBalance.estimate(r: .nan, g: 0.3, b: 0.3))
        XCTAssertNil(AutoWhiteBalance.estimate(r: 0.3, g: -1, b: 0.3))
    }

    func testAverageIgnoresClippedAndBlackPixelsButFallsBackWhenNothingLeft() throws {
        // 4 画素: 黒・白・(200,100,50)・(200,100,50)
        let px: [UInt8] = [0, 0, 0, 255, 255, 255, 255, 255, 200, 100, 50, 255, 200, 100, 50, 255]
        let m = try XCTUnwrap(AutoWhiteBalance.averageColor(rgba: px, count: 4))
        XCTAssertEqual(m.r, lin(200), accuracy: 1e-9)
        XCTAssertEqual(m.b, lin(50), accuracy: 1e-9)
        let allBlack = try XCTUnwrap(AutoWhiteBalance.averageColor(rgba: [UInt8](repeating: 0, count: 16), count: 4))
        XCTAssertEqual(allBlack.r, 0)
        XCTAssertNil(AutoWhiteBalance.estimate(r: allBlack.r, g: allBlack.g, b: allBlack.b), "真っ黒は決められない")
        XCTAssertNil(AutoWhiteBalance.averageColor(rgba: [1, 2, 3], count: 4), "足りない入力は nil")
    }

    // MARK: クリップに当てる

    func clip() -> Clip { var c = Clip(); c.type = .image; c.src = "a.png"; c.start = 0; c.duration = 2; return c }

    func testApplyAddsEffectOnceThenUpdatesInPlaceAndClearsItsKeyframes() {
        var c = clip()
        XCTAssertFalse(AutoWhiteBalance.apply(.init(temperature: 0, tint: 0), to: &c), "灰色でエフェクトも無いなら何もしない")
        XCTAssertTrue(c.effects.isEmpty)
        XCTAssertTrue(AutoWhiteBalance.apply(.init(temperature: -0.4, tint: 0.1), to: &c))
        XCTAssertEqual(c.effects.count, 1)
        XCTAssertEqual(c.effects[0].value("temperature"), -0.4, accuracy: 1e-9)
        XCTAssertFalse(AutoWhiteBalance.apply(.init(temperature: -0.4, tint: 0.1), to: &c), "同じ値は変化なし")
        c.effects[0].enabled = false
        c.keyframes["fx.0.temperature"] = [Keyframe(t: 0, v: 0.5)]
        XCTAssertTrue(AutoWhiteBalance.apply(.init(temperature: 0.2, tint: 0), to: &c))
        XCTAssertEqual(c.effects.count, 1)
        XCTAssertTrue(c.effects[0].enabled)
        XCTAssertNil(c.keyframes["fx.0.temperature"])
        XCTAssertTrue(AutoWhiteBalance.apply(.init(temperature: 0, tint: 0), to: &c), "エフェクトがあれば 0 に戻す")
        var text = Clip(); text.type = .audio
        XCTAssertFalse(AutoWhiteBalance.apply(.init(temperature: 0.2, tint: 0), to: &text), "音のクリップには付けない")
    }

    func testMeasurementProjectKeepsOnlyTheClipWithoutEffects() throws {
        var c = clip(); c.effects = [Effect(.whiteBalance), Effect(.sepia)]; c.opacity = 0.2
        c.keyframes["fx.0.temperature"] = [Keyframe(t: 0, v: 1)]
        var p = Project(); p.width = 1920; p.height = 1080
        var a = Track(); a.clips = [c]; var b = Track(); b.clips = [clip()]
        p.tracks = [a, b]; p.rangeIn = 1
        let m = try XCTUnwrap(AutoWhiteBalance.measurementProject(for: c, in: p))
        XCTAssertEqual(m.width, 192); XCTAssertEqual(m.height, 108)
        XCTAssertEqual(m.allClips.count, 1)
        XCTAssertTrue(m.allClips[0].effects.isEmpty)
        XCTAssertNil(m.allClips[0].opacity)
        XCTAssertTrue(m.allClips[0].keyframes.isEmpty)
        XCTAssertEqual(p.tracks.count, 2, "元は変わらない")
        XCTAssertEqual(p.allClips[0].effects.count, 2)
        var t = clip(); t.type = .text
        XCTAssertNil(AutoWhiteBalance.measurementProject(for: t, in: p), "文字クリップは測らない")
    }

    // MARK: 描画経路での確認

    private func tmpPNG(_ r: Int, _ g: Int, _ b: Int) throws -> String {
        let size = 40
        let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1))
        c.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("awb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("c.png")
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, c.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url.path
    }

    private func renderMean(_ p: Project) throws -> (r: Double, g: Double, b: Double) {
        let img = try XCTUnwrap(Renderer(project: p, assets: RenderAssets()).renderImage(t: 0.5))
        return try XCTUnwrap(AutoWhiteBalance.averageColor(of: img))
    }

    /// 色かぶりのある一色の画像を、測る → 決める → エフェクトを足す → 同じ描画経路で描く。かぶりが大きく減る。
    func testEndToEndReducesColorCastThroughRealRenderer() throws {
        let casts: [(String, (Int, Int, Int))] = [("暖色", (150, 128, 108)), ("寒色", (122, 128, 138)), ("緑", (115, 135, 115)), ("紫", (138, 118, 138))]
        for (name, rgb) in casts {
            var c = clip(); c.id = "i"; c.src = try tmpPNG(rgb.0, rgb.1, rgb.2); c.x = 0.5; c.y = 0.5; c.scale = 4
            var p = Project(); p.width = 192; p.height = 108; p.bg = "#000000"; p.characters = []
            var t = Track(name: "L1"); t.clips = [c]; p.tracks = [t]

            let before = try renderMean(p)
            let measure = try XCTUnwrap(AutoWhiteBalance.measurementProject(for: c, in: p))
            let img = try XCTUnwrap(Renderer(project: measure, assets: RenderAssets()).renderImage(t: 0.5))
            let result = try XCTUnwrap(AutoWhiteBalance.estimate(from: img), name)
            XCTAssertFalse(result.isNeutral, name)

            var fixed = c
            XCTAssertTrue(AutoWhiteBalance.apply(result, to: &fixed))
            var p2 = p; p2.tracks[0].clips = [fixed]
            let after = try renderMean(p2)

            func cast(_ m: (r: Double, g: Double, b: Double)) -> Double {
                max(abs(log2(m.r / m.b)), abs(log2(m.g / ((m.r + m.b) / 2))))
            }
            XCTAssertLessThan(cast(after), cast(before) * 0.35, "\(name): 前 \(cast(before)) → 後 \(cast(after)) (\(result))")
            XCTAssertLessThan(cast(after), 0.2, name)
        }
    }

    /// 強いかぶり(エフェクトの範囲 −1〜1 で直せる限界を超える)でも、悪くはならず、少しは近づく。
    func testStrongCastImprovesButMayNotFullyCorrect() throws {
        var c = clip(); c.src = try tmpPNG(100, 140, 200); c.x = 0.5; c.y = 0.5; c.scale = 4
        var p = Project(); p.width = 192; p.height = 108; p.bg = "#000000"; p.characters = []
        var t = Track(name: "L1"); t.clips = [c]; p.tracks = [t]
        let before = try renderMean(p)
        let m = try XCTUnwrap(AutoWhiteBalance.measurementProject(for: c, in: p))
        let result = try XCTUnwrap(AutoWhiteBalance.estimate(from: try XCTUnwrap(Renderer(project: m, assets: RenderAssets()).renderImage(t: 0.5))))
        XCTAssertEqual(result.temperature, 1, "範囲の端")
        var fixed = c
        AutoWhiteBalance.apply(result, to: &fixed)
        var p2 = p; p2.tracks[0].clips = [fixed]
        let after = try renderMean(p2)
        XCTAssertLessThan(abs(log2(after.r / after.b)), abs(log2(before.r / before.b)))
    }

    func testAlreadyNeutralImageGetsNoEffect() throws {
        var c = clip(); c.src = try tmpPNG(128, 128, 128); c.x = 0.5; c.y = 0.5; c.scale = 4
        var p = Project(); p.width = 192; p.height = 108; p.characters = []
        var t = Track(name: "L1"); t.clips = [c]; p.tracks = [t]
        let m = try XCTUnwrap(AutoWhiteBalance.measurementProject(for: c, in: p))
        let result = try XCTUnwrap(AutoWhiteBalance.estimate(from: try XCTUnwrap(Renderer(project: m, assets: RenderAssets()).renderImage(t: 0.5))))
        XCTAssertTrue(result.isNeutral)
        var fixed = c
        XCTAssertFalse(AutoWhiteBalance.apply(result, to: &fixed))
    }
}
