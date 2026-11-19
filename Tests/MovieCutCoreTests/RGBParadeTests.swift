import XCTest
import CoreGraphics
@testable import MovieCutCore

/// RGB パレード(チャンネル分離と列の対応を合成画像で確かめる)。
final class RGBParadeTests: XCTestCase {
    private func image(w: Int, h: Int, _ pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) -> [UInt8] {
        var out = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let (r, g, b) = pixel(x, y)
            let i = (y * w + x) * 4
            out[i] = r; out[i + 1] = g; out[i + 2] = b
        } }
        return out
    }

    func testChannelsAreSeparatedForSolidColor() throws {
        let px = image(w: 40, h: 30) { _, _ in (200, 100, 50) }
        let r = try XCTUnwrap(RGBParade.analyze(rgba: px, width: 40, height: 30, columns: 4))
        // 各チャンネルは自分の段だけに全画素が入る(他チャンネルの段には入らない)
        for col in 0..<4 {
            XCTAssertEqual(r.red[col * 256 + 200], 300, "赤は 200 の段")
            XCTAssertEqual(r.red[col * 256 + 100], 0)
            XCTAssertEqual(r.red[col * 256 + 50], 0)
            XCTAssertEqual(r.green[col * 256 + 100], 300, "緑は 100 の段")
            XCTAssertEqual(r.green[col * 256 + 200], 0)
            XCTAssertEqual(r.blue[col * 256 + 50], 300, "青は 50 の段")
            XCTAssertEqual(r.blue[col * 256 + 200], 0)
        }
        XCTAssertEqual(r.red.reduce(0, +), 1200)
        XCTAssertEqual(r.green.reduce(0, +), 1200)
        XCTAssertEqual(r.blue.reduce(0, +), 1200)
        XCTAssertEqual(r.sampledCount, 1200)
    }

    func testPureRedOnlyAppearsInRedChannel() throws {
        let px = image(w: 10, h: 10) { _, _ in (255, 0, 0) }
        let r = try XCTUnwrap(RGBParade.analyze(rgba: px, width: 10, height: 10, columns: 2))
        XCTAssertEqual(r.red.reduce(0, +), 100)
        XCTAssertEqual(r.red[0 * 256 + 255], 50)
        // 緑・青は 0 の段にだけ集まる(255 の段には何も無い = チャンネルが混ざっていない)
        XCTAssertEqual(r.green[0 * 256 + 0], 50)
        XCTAssertEqual(r.green[0 * 256 + 255], 0)
        XCTAssertEqual(r.blue[1 * 256 + 0], 50)
        XCTAssertEqual(r.blue[1 * 256 + 255], 0)
    }

    func testColumnsFollowHorizontalPosition() throws {
        // 左半分は赤、右半分は青
        let px = image(w: 20, h: 6) { x, _ in x < 10 ? (255, 0, 0) : (0, 0, 255) }
        let r = try XCTUnwrap(RGBParade.analyze(rgba: px, width: 20, height: 6, columns: 2))
        XCTAssertEqual(r.red[0 * 256 + 255], 60, "左列の赤は高い")
        XCTAssertEqual(r.red[1 * 256 + 255], 0, "右列に赤は無い")
        XCTAssertEqual(r.red[1 * 256 + 0], 60)
        XCTAssertEqual(r.blue[1 * 256 + 255], 60, "右列の青は高い")
        XCTAssertEqual(r.blue[0 * 256 + 255], 0)
    }

    func testHorizontalRampSpreadsEachChannel() throws {
        // 赤だけ横勾配、緑・青は 0 固定
        let w = 256, h = 4
        let px = image(w: w, h: h) { x, _ in (UInt8(x), 0, 0) }
        let r = try XCTUnwrap(RGBParade.analyze(rgba: px, width: w, height: h, columns: 256))
        for c in [0, 100, 255] {
            XCTAssertEqual(r.red[c * 256 + c], h, "列 \(c) の赤は段 \(c)")
            XCTAssertEqual(r.green[c * 256 + 0], h, "緑は全列 0 の段")
            XCTAssertEqual(r.blue[c * 256 + 0], h)
        }
    }

    func testBlackAndWhiteEdges() throws {
        let px = image(w: 10, h: 10) { x, _ in x < 5 ? (0, 0, 0) : (255, 255, 255) }
        let r = try XCTUnwrap(RGBParade.analyze(rgba: px, width: 10, height: 10, columns: 2))
        for channel in [r.red, r.green, r.blue] {
            XCTAssertEqual(channel[0 * 256 + 0], 50)
            XCTAssertEqual(channel[1 * 256 + 255], 50)
        }
    }

    func testColumnsAreClampedToWidth() throws {
        let px = image(w: 8, h: 2) { _, _ in (10, 20, 30) }
        let r = try XCTUnwrap(RGBParade.analyze(rgba: px, width: 8, height: 2, columns: 256))
        XCTAssertEqual(r.columns, 8)
    }

    func testSamplingStrideCapsSamples() throws {
        let px = image(w: 1024, h: 1024) { _, y in (0, UInt8(y % 256), 0) }
        let r = try XCTUnwrap(RGBParade.analyze(rgba: px, width: 1024, height: 1024, columns: 16, maxSamples: 65_536))
        XCTAssertEqual(r.stride, 4)
        XCTAssertEqual(r.sampledCount, 65_536)
        XCTAssertEqual(r.red.reduce(0, +), r.sampledCount)
        XCTAssertEqual(r.green.reduce(0, +), r.sampledCount)
    }

    func testBadInputIsRejected() {
        XCTAssertNil(RGBParade.analyze(rgba: [0, 0, 0], width: 1, height: 1))
        XCTAssertNil(RGBParade.analyze(rgba: [], width: 0, height: 0))
    }

    func testCGImagePathMatchesRawPixels() throws {
        let w = 32, h = 16
        let px = image(w: w, h: h) { x, y in (UInt8(x * 8), UInt8(y * 16), 40) }
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.data!.copyMemory(from: px, byteCount: px.count)
        let img = try XCTUnwrap(ctx.makeImage())
        let fromImage = try XCTUnwrap(RGBParade.analyze(img))
        let fromRaw = try XCTUnwrap(RGBParade.analyze(rgba: px, width: w, height: h))
        XCTAssertEqual(fromImage.red, fromRaw.red)
        XCTAssertEqual(fromImage.green, fromRaw.green)
        XCTAssertEqual(fromImage.blue, fromRaw.blue)
    }
}
