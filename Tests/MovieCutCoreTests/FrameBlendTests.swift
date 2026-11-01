import XCTest
import CoreGraphics
@testable import MovieCutCore

/// フレームブレンド: 2 コマの重ね合わせの画素(中間の時刻は両端の比で混ざる)と、1080p での 1 回あたりの時間。
final class FrameBlendTests: XCTestCase {
    func solid(_ r: UInt8, _ g: UInt8, _ b: UInt8, w: Int, h: Int) -> CGImage {
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info)!
        ctx.setFillColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    /// 画像の左上の 1 画素を (r, g, b) で返す(BGRA の事前乗算。不透明なので値はそのまま)。
    func pixel(_ img: CGImage) -> (Int, Int, Int) {
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        var buf = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &buf, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info)!
        ctx.draw(img, in: CGRect(x: -(img.width - 1) / 2, y: -(img.height - 1) / 2, width: img.width, height: img.height))
        return (Int(buf[2]), Int(buf[1]), Int(buf[0]))
    }

    func testMidTimePixelIsTheMixOfTwoFrames() {
        let a = solid(255, 0, 0, w: 8, h: 8)     // 赤
        let b = solid(0, 0, 255, w: 8, h: 8)     // 青
        let half = FrameBlend.mix(a, b, weight: 0.5)!
        let (r, g, bl) = pixel(half)
        XCTAssertLessThanOrEqual(abs(r - 128), 1); XCTAssertEqual(g, 0); XCTAssertLessThanOrEqual(abs(bl - 128), 1)
        let quarter = FrameBlend.mix(a, b, weight: 0.25)!
        let (r2, _, b2) = pixel(quarter)
        XCTAssertLessThanOrEqual(abs(r2 - 191), 1, "a の 0.75")
        XCTAssertLessThanOrEqual(abs(b2 - 64), 1, "b の 0.25")
    }

    func testEndpointsReturnTheFramesThemselves() {
        let a = solid(10, 20, 30, w: 4, h: 4), b = solid(200, 100, 50, w: 4, h: 4)
        XCTAssertTrue(FrameBlend.mix(a, b, weight: 0) === a)
        XCTAssertTrue(FrameBlend.mix(a, b, weight: 1) === b)
    }

    func testBlendOnlyForSlowForwardVideo() {
        var c = Clip(); c.id = "v"; c.type = .video; c.src = "/tmp/none.mp4"; c.start = 0; c.duration = 2; c.offset = 0
        c.speed = 0.5; c.frameBlend = true
        XCTAssertTrue(ClipTiming.blendsFrames(c, atClipTime: 1))
        c.reverse = true
        XCTAssertFalse(ClipTiming.blendsFrames(c, atClipTime: 1), "逆再生では混ぜない")
        c.reverse = nil; c.speed = 2
        XCTAssertFalse(ClipTiming.blendsFrames(c, atClipTime: 1), "速い側では混ぜない")
        c.speed = nil; c.speedRamp = [SpeedKey(t: 0, v: 2), SpeedKey(t: 2, v: 0.5)]
        XCTAssertFalse(ClipTiming.blendsFrames(c, atClipTime: 0.1), "ランプの頭は 2 倍")
        XCTAssertTrue(ClipTiming.blendsFrames(c, atClipTime: 1.9), "ランプの終わり近くは 1 未満")
    }

    /// 1080p の 1 回あたりの時間(計測値を出す。性能の上限は決めない)。
    func testMixCostAt1080p() {
        let a = solid(200, 80, 40, w: 1920, h: 1080), b = solid(40, 80, 200, w: 1920, h: 1080)
        _ = FrameBlend.mix(a, b, weight: 0.5)
        let n = 20
        let t0 = CFAbsoluteTimeGetCurrent()
        for _ in 0..<n { _ = FrameBlend.mix(a, b, weight: 0.5) }
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000 / Double(n)
        print("[FrameBlend] 1920x1080 mix: \(String(format: "%.2f", ms)) ms/op (n=\(n))")
        XCTAssertNotNil(FrameBlend.mix(a, b, weight: 0.5))
    }
}
