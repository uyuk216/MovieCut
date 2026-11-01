import XCTest
import CoreGraphics
@testable import MovieCutCore

/// 映像スコープ(合成の勾配・単色で確かめる)。
final class VideoScopeTests: XCTestCase {
    /// 幅 w・高さ h の RGBA。`pixel(x, y)` の値を入れる。
    private func image(w: Int, h: Int, _ pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) -> [UInt8] {
        var out = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let (r, g, b) = pixel(x, y)
            let i = (y * w + x) * 4
            out[i] = r; out[i + 1] = g; out[i + 2] = b
        } }
        return out
    }

    func testSolidColorPutsEverythingInOneBin() throws {
        let px = image(w: 40, h: 30) { _, _ in (200, 100, 50) }
        let r = try XCTUnwrap(VideoScope.analyze(rgba: px, width: 40, height: 30))
        XCTAssertEqual(r.red[200], 1200)
        XCTAssertEqual(r.red.reduce(0, +), 1200)
        XCTAssertEqual(r.green[100], 1200)
        XCTAssertEqual(r.blue[50], 1200)
        // 輝度 = 0.2126·200 + 0.7152·100 + 0.0722·50 = 42.52 + 71.52 + 3.61 = 117.65 → 118
        XCTAssertEqual(r.luma[118], 1200)
        XCTAssertEqual(r.luma.reduce(0, +), 1200)
    }

    func testHorizontalRampIsFlatInHistogramAndDiagonalInWaveform() throws {
        // 横方向に 0〜255 の勾配(幅 256 なら 1 列 = 1 段)
        let w = 256, h = 8
        let px = image(w: w, h: h) { x, _ in (UInt8(x), UInt8(x), UInt8(x)) }
        let r = try XCTUnwrap(VideoScope.analyze(rgba: px, width: w, height: h, columns: 256))
        XCTAssertEqual(r.red.reduce(0, +), w * h)
        XCTAssertEqual(r.red.max(), h, "各段に 1 列ぶん(8 画素)")
        XCTAssertEqual(r.red.min(), h)
        // 波形: 列 c には、輝度 c だけが入る
        for c in [0, 1, 100, 255] {
            XCTAssertEqual(r.waveform[c * 256 + c], h, "列 \(c) は段 \(c) に \(h) 画素")
            XCTAssertEqual(r.waveform[c * 256..<(c + 1) * 256].reduce(0, +), h)
        }
    }

    func testVerticalRampShowsEachLevelOnce() throws {
        // 縦方向の勾配: 上から下へ 0〜255(高さ 256)。輝度ヒストグラムは段ごとに同じ数。
        let w = 16, h = 256
        let px = image(w: w, h: h) { _, y in (UInt8(y), UInt8(y), UInt8(y)) }
        let r = try XCTUnwrap(VideoScope.analyze(rgba: px, width: w, height: h, columns: 4))
        XCTAssertEqual(r.luma.min(), w)
        XCTAssertEqual(r.luma.max(), w)
        XCTAssertEqual(r.columns, 4)
        // 波形の 1 列(4 画素幅ぶん)は、全段に同じ数
        XCTAssertEqual(r.waveform[0], w / 4 * 1)
        XCTAssertEqual(r.waveform[0 * 256 + 255], w / 4 * 1)
    }

    func testBlackAndWhiteEdges() throws {
        let px = image(w: 10, h: 10) { x, _ in x < 5 ? (0, 0, 0) : (255, 255, 255) }
        let r = try XCTUnwrap(VideoScope.analyze(rgba: px, width: 10, height: 10))
        XCTAssertEqual(r.luma[0], 50)
        XCTAssertEqual(r.luma[255], 50)
        XCTAssertEqual(r.red.reduce(0, +), 100)
    }

    func testBadInputIsRejected() {
        XCTAssertNil(VideoScope.analyze(rgba: [0, 0, 0], width: 1, height: 1))
        XCTAssertNil(VideoScope.analyze(rgba: [], width: 0, height: 0))
    }

    func testIntensityIsMonotonicAndBounded() {
        XCTAssertEqual(VideoScope.intensity(0, max: 100), 0)
        XCTAssertEqual(VideoScope.intensity(100, max: 100), 1, accuracy: 1e-9)
        XCTAssertLessThan(VideoScope.intensity(1, max: 1000), VideoScope.intensity(10, max: 1000))
        XCTAssertLessThanOrEqual(VideoScope.intensity(5, max: 3), 1.0 + 1e-9, "最大より多くても 1 を超えない")
        XCTAssertEqual(VideoScope.intensity(5, max: 0), 0)
    }

    func testCGImagePathMatchesRawPixels() throws {
        let w = 32, h = 16
        let px = image(w: w, h: h) { x, y in (UInt8(x * 8), UInt8(y * 16), 40) }
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.data!.copyMemory(from: px, byteCount: px.count)
        let img = try XCTUnwrap(ctx.makeImage())
        let fromImage = try XCTUnwrap(VideoScope.analyze(img))
        let fromRaw = try XCTUnwrap(VideoScope.analyze(rgba: px, width: w, height: h))
        XCTAssertEqual(fromImage.red, fromRaw.red)
        XCTAssertEqual(fromImage.luma, fromRaw.luma)
        XCTAssertEqual(fromImage.waveform, fromRaw.waveform)
    }
}
