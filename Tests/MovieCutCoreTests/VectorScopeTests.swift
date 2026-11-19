import XCTest
import CoreGraphics
@testable import MovieCutCore

/// ベクトルスコープ(座標変換は Rec.709 色差の手計算と照合、分布は合成画像で確かめる)。
final class VectorScopeTests: XCTestCase {
    private func image(w: Int, h: Int, _ pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) -> [UInt8] {
        var out = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let (r, g, b) = pixel(x, y)
            let i = (y * w + x) * 4
            out[i] = r; out[i + 1] = g; out[i + 2] = b
        } }
        return out
    }

    // MARK: 座標変換(既知の色)

    func testGrayHasNoChroma() {
        for v: UInt8 in [0, 1, 128, 255] {
            let c = VectorScope.chroma(red: v, green: v, blue: v)
            XCTAssertEqual(c.cb, 0, accuracy: 1e-9, "グレー \(v) は無彩色")
            XCTAssertEqual(c.cr, 0, accuracy: 1e-9)
            XCTAssertEqual(c.radius, 0, accuracy: 1e-9)
        }
    }

    func testPureColorsLandOnKnownPositions() {
        // Y = 0.2126R + 0.7152G + 0.0722B、Cb = (B−Y)/1.8556、Cr = (R−Y)/1.5748 で手計算した値。
        let cases: [(UInt8, UInt8, UInt8, Double, Double)] = [
            (255, 0, 0, -0.1146, 0.5000),    // 赤: 上・わずかに左
            (0, 255, 0, -0.3854, -0.4542),   // 緑: 左下
            (0, 0, 255, 0.5000, -0.0458),    // 青: 右・わずかに下
            (255, 255, 0, -0.5000, 0.0458),  // 黄: 左・わずかに上
            (0, 255, 255, 0.1146, -0.5000),  // シアン: 下・わずかに右
            (255, 0, 255, 0.3854, 0.4542),   // マゼンタ: 右上
        ]
        for (r, g, b, cb, cr) in cases {
            let c = VectorScope.chroma(red: r, green: g, blue: b)
            XCTAssertEqual(c.cb, cb, accuracy: 1e-3, "(\(r),\(g),\(b)) の Cb")
            XCTAssertEqual(c.cr, cr, accuracy: 1e-3, "(\(r),\(g),\(b)) の Cr")
        }
    }

    func testRedAngleAndRadius() {
        let c = VectorScope.chroma(red: 255, green: 0, blue: 0)
        XCTAssertEqual(c.angleDegrees, 102.9, accuracy: 0.2)
        XCTAssertEqual(c.radius, 0.513, accuracy: 0.002)
        XCTAssertEqual(c.normalizedX, c.cb * 2, accuracy: 1e-12)
        XCTAssertEqual(c.normalizedY, c.cr * 2, accuracy: 1e-12)
    }

    func testSaturationScalesRadius() {
        // 同じ色相で彩度を落とす(グレーへ寄せる)と、中心へ近づく。
        let vivid = VectorScope.chroma(red: 255, green: 0, blue: 0)
        let pale = VectorScope.chroma(red: 192, green: 64, blue: 64)
        XCTAssertLessThan(pale.radius, vivid.radius)
        XCTAssertEqual(pale.angleDegrees, vivid.angleDegrees, accuracy: 0.5, "色相(角度)は概ね保たれる")
    }

    func testSkinToneColorsSitNearSkinToneLine() {
        for (r, g, b) in [(UInt8(200), UInt8(150), UInt8(120)), (UInt8(180), UInt8(120), UInt8(90)), (UInt8(220), UInt8(170), UInt8(140))] {
            let c = VectorScope.chroma(red: r, green: g, blue: b)
            XCTAssertEqual(c.angleDegrees, VectorScope.skinToneAngleDegrees, accuracy: 6, "肌色 (\(r),\(g),\(b)) はスキントーンライン付近")
        }
        let end = VectorScope.skinToneLineEnd
        XCTAssertEqual(hypot(end.x, end.y), 0.9, accuracy: 1e-9)
        XCTAssertEqual(atan2(end.y, end.x) * 180 / .pi, VectorScope.skinToneAngleDegrees, accuracy: 1e-9)
    }

    func testTargetsCoverSixPureColors() {
        XCTAssertEqual(VectorScope.targets.map(\.name), ["R", "M", "B", "C", "G", "Y"])
        for t in VectorScope.targets {
            XCTAssertGreaterThan(t.chroma.radius, 0.49, "\(t.name) は外周付近")
            XCTAssertLessThan(t.chroma.radius, 0.61)
        }
    }

    // MARK: グリッドへの分布

    func testGridCellCornersAndCenter() {
        let size = VectorScope.gridSize
        let center = VectorScope.gridCell(normalizedX: 0, normalizedY: 0)
        XCTAssertEqual(center.column, size / 2)
        XCTAssertEqual(center.row, size / 2)
        let topLeft = VectorScope.gridCell(normalizedX: -1, normalizedY: 1)
        XCTAssertEqual(topLeft.column, 0); XCTAssertEqual(topLeft.row, 0)
        let bottomRight = VectorScope.gridCell(normalizedX: 0.999, normalizedY: -0.999)
        XCTAssertEqual(bottomRight.column, size - 1); XCTAssertEqual(bottomRight.row, size - 1)
        // 範囲外は端に寄せる
        let clamped = VectorScope.gridCell(normalizedX: 3, normalizedY: -3)
        XCTAssertEqual(clamped.column, size - 1); XCTAssertEqual(clamped.row, size - 1)
    }

    func testSolidRedConcentratesInOneUpperCell() throws {
        let px = image(w: 20, h: 10) { _, _ in (255, 0, 0) }
        let r = try XCTUnwrap(VectorScope.analyze(rgba: px, width: 20, height: 10))
        XCTAssertEqual(r.sampledCount, 200)
        XCTAssertEqual(r.totalCount, 200)
        XCTAssertEqual(r.stride, 1)
        XCTAssertEqual(r.grid.reduce(0, +), 200)
        XCTAssertEqual(r.maxCount, 200, "単色は 1 マスに集まる")
        let nonzero = r.grid.enumerated().filter { $0.element > 0 }
        XCTAssertEqual(nonzero.count, 1)
        let idx = nonzero[0].offset
        let row = idx / r.size, col = idx % r.size
        // 赤: Cb が負(左寄り)、Cr が最大(最上段)
        XCTAssertLessThan(col, r.size / 2)
        XCTAssertEqual(row, 0)
        let expected = VectorScope.gridCell(normalizedX: VectorScope.chroma(red: 255, green: 0, blue: 0).normalizedX,
                                            normalizedY: VectorScope.chroma(red: 255, green: 0, blue: 0).normalizedY)
        XCTAssertEqual(col, expected.column); XCTAssertEqual(row, expected.row)
    }

    func testSolidBlueIsRightAndSlightlyBelowCenter() throws {
        let px = image(w: 8, h: 8) { _, _ in (0, 0, 255) }
        let r = try XCTUnwrap(VectorScope.analyze(rgba: px, width: 8, height: 8))
        let idx = try XCTUnwrap(r.grid.enumerated().first { $0.element > 0 }).offset
        XCTAssertEqual(idx % r.size, r.size - 1, "青は右端")
        XCTAssertGreaterThan(idx / r.size, r.size / 2, "青は中心よりわずかに下")
    }

    func testGrayImageConcentratesAtCenter() throws {
        let px = image(w: 16, h: 16) { _, _ in (128, 128, 128) }
        let r = try XCTUnwrap(VectorScope.analyze(rgba: px, width: 16, height: 16))
        XCTAssertEqual(r.maxCount, 256)
        let c = VectorScope.gridCell(normalizedX: 0, normalizedY: 0)
        XCTAssertEqual(r.grid[c.row * r.size + c.column], 256)
    }

    func testSamplingStrideCapsSamples() throws {
        // 1024×1024 = 1,048,576 画素、上限 65,536 なら歩幅 4 で 65,536 サンプル。
        let px = image(w: 1024, h: 1024) { x, _ in (UInt8(x % 256), 0, 0) }
        let r = try XCTUnwrap(VectorScope.analyze(rgba: px, width: 1024, height: 1024, maxSamples: 65_536))
        XCTAssertEqual(r.stride, 4)
        XCTAssertEqual(r.sampledCount, 65_536)
        XCTAssertEqual(r.totalCount, 1_048_576)
        XCTAssertEqual(r.grid.reduce(0, +), r.sampledCount)
    }

    func testBadInputIsRejected() {
        XCTAssertNil(VectorScope.analyze(rgba: [0, 0, 0], width: 1, height: 1))
        XCTAssertNil(VectorScope.analyze(rgba: [], width: 0, height: 0))
    }

    func testCGImagePathMatchesRawPixels() throws {
        let w = 32, h = 16
        let px = image(w: w, h: h) { x, y in (UInt8(x * 8), UInt8(y * 16), 40) }
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.data!.copyMemory(from: px, byteCount: px.count)
        let img = try XCTUnwrap(ctx.makeImage())
        let fromImage = try XCTUnwrap(VectorScope.analyze(img))
        let fromRaw = try XCTUnwrap(VectorScope.analyze(rgba: px, width: w, height: h))
        XCTAssertEqual(fromImage.grid, fromRaw.grid)
        XCTAssertEqual(fromImage.sampledCount, fromRaw.sampledCount)
    }
}
