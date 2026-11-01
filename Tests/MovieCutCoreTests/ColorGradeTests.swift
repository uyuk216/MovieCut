import XCTest
import CoreGraphics
import CoreImage
@testable import MovieCutCore

/// 色補正: ホワイトバランス(色温度・ティント)とカラーホイール(持ち上げ・ガンマ・ゲイン)の画素の確認。
final class ColorGradeTests: XCTestCase {
    private let rect = CGRect(x: 0, y: 0, width: 16, height: 16)

    private func solid(_ r: Int, _ g: Int, _ b: Int, alpha: Double = 1) -> CIImage {
        CIImage(color: CIColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: CGFloat(alpha))).cropped(to: rect)
    }

    /// 1 種類のエフェクトを画像にかけ、中央の画素(RGBA・0〜255)を返す。
    private func run(_ kind: EffectKind, _ values: [String: Double], on img: CIImage) -> [Int] {
        let fx = ResolvedEffect(kind: kind, values: values, color: "#000000")
        let out = EffectPipeline.applyOne(fx, img, rect: rect, bounds: rect, scale: 1)
        guard let cg = EffectPipeline.makeImage(out, from: rect) else { return [-1, -1, -1, -1] }
        var d = [UInt8](repeating: 0, count: 16 * 16 * 4)
        let c = CGContext(data: &d, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(cg, in: CGRect(x: 0, y: 0, width: 16, height: 16))
        let i = (8 * 16 + 8) * 4
        return [Int(d[i]), Int(d[i + 1]), Int(d[i + 2]), Int(d[i + 3])]
    }

    private func wb(_ t: Double, _ tint: Double = 0) -> [String: Double] { ["temperature": t, "tint": tint] }
    private func wheels(lift: (Double, Double) = (0, 0), gamma: (Double, Double) = (0, 0), gain: (Double, Double) = (0, 0)) -> [String: Double] {
        ["liftAngle": lift.0, "liftAmount": lift.1, "gammaAngle": gamma.0, "gammaAmount": gamma.1, "gainAngle": gain.0, "gainAmount": gain.1]
    }

    func testTemperaturePositiveWarmsAndNegativeCools() {
        let gray = solid(128, 128, 128)
        let warm = run(.whiteBalance, wb(1), on: gray)
        XCTAssertGreaterThan(warm[0], warm[2] + 10, "色温度 + は暖かく(R > B): \(warm)")
        let cool = run(.whiteBalance, wb(-1), on: gray)
        XCTAssertGreaterThan(cool[2], cool[0] + 10, "色温度 − は冷たく(B > R): \(cool)")
    }

    func testTintMovesGreenInTheOppositeDirections() {
        let gray = solid(128, 128, 128)
        let plus = run(.whiteBalance, wb(0, 1), on: gray)
        let minus = run(.whiteBalance, wb(0, -1), on: gray)
        let zero = run(.whiteBalance, wb(0, 0), on: gray)
        XCTAssertLessThan(plus[1], minus[1], "ティント + は紫寄り(緑が減る)")
        XCTAssertEqual(zero[0], 128, accuracy: 1)
        XCTAssertEqual(zero[1], 128, accuracy: 1)
        XCTAssertEqual(zero[2], 128, accuracy: 1, "ティント 0 と色温度 0 は変えない")
    }

    func testWhiteBalanceKeepsTransparency() {
        let clear = solid(0, 0, 0, alpha: 0)
        XCTAssertEqual(run(.whiteBalance, wb(1), on: clear)[3], 0)
    }

    func testIdentityWheelsDoNothing() {
        let gray = solid(120, 90, 200)
        let v = run(.colorWheels, wheels(), on: gray)
        XCTAssertEqual(v[0], 120, accuracy: 1)
        XCTAssertEqual(v[1], 90, accuracy: 1)
        XCTAssertEqual(v[2], 200, accuracy: 1)
    }

    func testLiftTintsShadowsOnlyInItsHue() {
        // 持ち上げを赤(角度 0)に強く。真っ黒は赤だけ持ち上がる
        let black = run(.colorWheels, wheels(lift: (0, 1)), on: solid(0, 0, 0))
        XCTAssertGreaterThan(black[0], 20)
        XCTAssertEqual(black[1], 0)
        XCTAssertEqual(black[2], 0)
        // 真っ白は持ち上げで動かない(影だけ)
        let white = run(.colorWheels, wheels(lift: (0, 1)), on: solid(255, 255, 255))
        XCTAssertEqual(white[0], 255, accuracy: 1)
    }

    func testGainScalesHighlightsOfTheHue() {
        // ゲインを赤に。中間の灰色は赤だけ明るくなる
        let g = run(.colorWheels, wheels(gain: (0, 1)), on: solid(128, 128, 128))
        XCTAssertGreaterThan(g[0], 128 + 20)
        XCTAssertLessThan(g[1], 128)
        XCTAssertLessThan(g[2], 128)
    }

    func testGammaBrightensMidtonesButKeepsBlackAndWhite() {
        let mid = run(.colorWheels, wheels(gamma: (0, 1)), on: solid(128, 128, 128))
        XCTAssertGreaterThan(mid[0], 128 + 10, "ガンマは中間の赤を持ち上げる")
        XCTAssertLessThan(mid[1], 128, "緑は逆に落ちる")
        XCTAssertEqual(run(.colorWheels, wheels(gamma: (0, 1)), on: solid(0, 0, 0))[0], 0)
        XCTAssertEqual(run(.colorWheels, wheels(gamma: (0, 1)), on: solid(255, 255, 255))[0], 255, accuracy: 1)
    }

    func testWheelsKeepTransparencyAndCubeSize() {
        XCTAssertEqual(run(.colorWheels, wheels(lift: (90, 1), gain: (0, 1)), on: solid(0, 0, 0, alpha: 0))[3], 0)
        let n = ColorWheels.dimension
        let data = ColorWheels.cubeData(lift: .init(angle: 0, amount: 0), gamma: .init(angle: 0, amount: 0), gain: .init(angle: 0, amount: 0))
        XCTAssertEqual(data.count, n * n * n * 4 * MemoryLayout<Float>.size)
    }

    func testNewKindsHaveDefaultsThatDoNothingAndKeyNames() {
        let e = Effect(.whiteBalance)
        XCTAssertNil(EffectPipeline.resolve(Clip.withEffects([e]), atClipTime: 0).first, "既定値は何もしない")
        XCTAssertEqual(EffectKind.colorWheels.params.count, 6)
        XCTAssertEqual(EffectKey.make(0, "liftAmount"), "fx.0.liftAmount")
    }
}

private extension Clip {
    static func withEffects(_ fx: [Effect]) -> Clip {
        var c = Clip(); c.type = .image; c.duration = 1; c.effects = fx; return c
    }
}
