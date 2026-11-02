import XCTest
import CoreGraphics
@testable import MovieCutCore

/// 背景抜き(前景マスク → アルファ)。検出器は固定マスクを渡す(実際の Vision は画面の無い環境で結果が変わるため、ここでは使わない)。
final class ForegroundCutoutTests: XCTestCase {
    private struct FixedMask: ForegroundMaskDetecting {
        var mask: CGImage?
        func foregroundMask(for image: CGImage) throws -> CGImage? { mask }
    }

    /// 幅 w・高さ h の RGBA(全部 `rgba`)。
    private func solid(_ w: Int, _ h: Int, _ rgba: (UInt8, UInt8, UInt8, UInt8)) -> CGImage {
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) { px[i * 4] = rgba.0; px[i * 4 + 1] = rgba.1; px[i * 4 + 2] = rgba.2; px[i * 4 + 3] = rgba.3 }
        return makeImage(w, h, px)
    }

    private func makeImage(_ w: Int, _ h: Int, _ px: [UInt8]) -> CGImage {
        let data = Data(px) as CFData
        let provider = CGDataProvider(data: data)!
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    /// 左半分が白(前景)、右半分が黒(背景)のマスク。
    private func leftHalfMask(_ w: Int, _ h: Int) -> CGImage {
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let v: UInt8 = x < w / 2 ? 255 : 0
            let i = (y * w + x) * 4
            px[i] = v; px[i + 1] = v; px[i + 2] = v; px[i + 3] = 255
        } }
        return makeImage(w, h, px)
    }

    /// (x, y) の RGBA を読む。
    private func pixel(_ img: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: &buf, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        let i = (y * img.width + x) * 4
        return Array(buf[i..<(i + 4)])
    }

    func testMaskDecidesAlphaLeftKeptRightTransparent() throws {
        let img = solid(8, 8, (200, 50, 50, 255))
        let out = try ForegroundCutout.cutout(img, detector: FixedMask(mask: leftHalfMask(8, 8)))
        XCTAssertEqual(out.width, 8)
        XCTAssertEqual(out.height, 8)
        let left = pixel(out, 1, 4)
        let right = pixel(out, 6, 4)
        XCTAssertGreaterThan(left[3], 250, "前景は残る")
        XCTAssertLessThan(right[3], 5, "背景は透明になる")
    }

    func testMaskOfOtherSizeIsStretchedToImage() throws {
        let img = solid(16, 16, (10, 10, 10, 255))
        let out = try ForegroundCutout.cutout(img, detector: FixedMask(mask: leftHalfMask(4, 4)))
        XCTAssertEqual(out.width, 16)
        XCTAssertGreaterThan(pixel(out, 3, 8)[3], 250)
        XCTAssertLessThan(pixel(out, 12, 8)[3], 5)
    }

    func testNoForegroundThrows() {
        let img = solid(4, 4, (0, 0, 0, 255))
        XCTAssertThrowsError(try ForegroundCutout.cutout(img, detector: FixedMask(mask: nil))) { e in
            XCTAssertEqual(e as? ForegroundCutoutError, .noForeground)
        }
    }

    func testPNGWriteAndReadKeepsTransparency() throws {
        let img = solid(8, 8, (200, 50, 50, 255))
        let out = try ForegroundCutout.cutout(img, detector: FixedMask(mask: leftHalfMask(8, 8)))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mc-cut-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("cut.png")
        try ForegroundCutout.writePNG(out, to: url)
        let back = try ForegroundCutout.readImage(at: url)
        XCTAssertLessThan(pixel(back, 6, 4)[3], 5, "透明は PNG に残る")
        XCTAssertGreaterThan(pixel(back, 1, 4)[3], 250)
    }

    func testUnreadableImageThrows() {
        let bad = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID().uuidString).png")
        XCTAssertThrowsError(try ForegroundCutout.readImage(at: bad)) { e in
            XCTAssertEqual(e as? ForegroundCutoutError, .unreadableImage(bad.lastPathComponent))
        }
    }
}
