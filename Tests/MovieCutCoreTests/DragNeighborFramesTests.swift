import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import MovieCutCore

/// ドラッグ中に出す「移動先の前後のコマ」の帯: 4 コマの時刻と、帯の画素(つなぎ目の前後で映っているもの)。
final class DragNeighborFramesTests: XCTestCase {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("neighbor-tests-\(UUID().uuidString)")
    override func setUpWithError() throws { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func png(_ name: String, r: CGFloat, g: CGFloat, b: CGFloat) throws -> String {
        let n = 32
        let c = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(red: r, green: g, blue: b, alpha: 1); c.fill(CGRect(x: 0, y: 0, width: n, height: n))
        let url = tmp.appendingPathComponent("\(name).png")
        let d = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(d, c.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(d))
        return url.path
    }

    func image(_ id: String, _ src: String, start: Double, duration: Double) -> Clip {
        var c = Clip(); c.id = id; c.type = .image; c.src = src; c.start = start; c.duration = duration; c.x = 0.5; c.y = 0.5; c.scale = 1
        return c
    }

    func rgb(_ img: CGImage, x: Int, y: Int) -> [Int] {
        var d = [UInt8](repeating: 0, count: 4)
        let c = CGContext(data: &d, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(img, in: CGRect(x: -x, y: -(img.height - 1 - y), width: img.width, height: img.height))
        return [Int(d[0]), Int(d[1]), Int(d[2])]
    }

    /// 帯の i 番目のコマの中央の色
    func cell(_ img: CGImage, _ i: Int) -> [Int] {
        let cw = DragNeighborFrames.cellWidth
        let x0 = [0, cw + 3, 2 * cw + 3 + 12, 3 * cw + 6 + 12][i]
        return rgb(img, x: x0 + cw / 2, y: img.height / 2)
    }

    func testTimesSnapToTheFrameGrid() throws {
        let r = FrameRate.from(30)
        let t = try XCTUnwrap(DragNeighborFrames.times(start: 2.01, end: 4.0, rate: r))
        XCTAssertEqual(t.headAfter, 2.0, accuracy: 1e-9, "格子へ")
        XCTAssertEqual(try XCTUnwrap(t.headBefore), 2.0 - 1.0 / 30, accuracy: 1e-9)
        XCTAssertEqual(t.tailBefore, 4.0 - 1.0 / 30, accuracy: 1e-9, "最後のコマ")
        XCTAssertEqual(t.tailAfter, 4.0, accuracy: 1e-9, "終わりの次のコマ")
        XCTAssertEqual(t.ordered.count, 4)
    }

    func testHeadAtZeroHasNoFrameBefore() throws {
        let t = try XCTUnwrap(DragNeighborFrames.times(start: 0, end: 1, rate: .from(60)))
        XCTAssertNil(t.headBefore)
        XCTAssertEqual(t.headAfter, 0)
        let t2 = try XCTUnwrap(DragNeighborFrames.times(start: -3, end: 1, rate: .from(60)), "負の頭は 0 に寄せる")
        XCTAssertNil(t2.headBefore); XCTAssertEqual(t2.headAfter, 0)
    }

    func testVeryShortClipAndInvalidInput() throws {
        let r = FrameRate.from(30)
        let t = try XCTUnwrap(DragNeighborFrames.times(start: 5, end: 5.001, rate: r))
        XCTAssertEqual(t.tailBefore, t.headAfter, accuracy: 1e-9, "1 コマに満たなければ最後 = 最初")
        XCTAssertGreaterThan(t.tailAfter, t.tailBefore)
        XCTAssertNil(DragNeighborFrames.times(start: 5, end: 5, rate: r))
        XCTAssertNil(DragNeighborFrames.times(start: 5, end: 4, rate: r))
        XCTAssertNil(DragNeighborFrames.times(start: .nan, end: 4, rate: r))
        XCTAssertNil(DragNeighborFrames.times(start: 1, end: .infinity, rate: r))
    }

    func testStripShowsTheJoinsAroundTheMovedClip() throws {
        let red = try png("red", r: 1, g: 0, b: 0), blue = try png("blue", r: 0, g: 0, b: 1)
        var p = Project(); p.width = 160; p.height = 90; p.fps = 30; p.bg = "#000000"; p.characters = []
        // 下のレイヤーに赤(0〜2 秒)と、動かした青(2〜4 秒)。青の後ろは何も無い(背景の黒)
        var t0 = Track(name: "L0"); t0.clips = [image("red", red, start: 0, duration: 2), image("blue", blue, start: 2, duration: 2)]
        p.tracks = [t0]
        let times = try XCTUnwrap(DragNeighborFrames.times(start: 2, end: 4, rate: p.frameRate))
        let strip = try XCTUnwrap(DragNeighborFrames.strip(project: p, assets: RenderAssets(), times: times))
        let size = DragNeighborFrames.stripSize(width: 160, height: 90)
        XCTAssertEqual(strip.width, Int(size.width)); XCTAssertEqual(strip.height, Int(size.height))
        XCTAssertEqual(size.height, 113, "200 × 90/160")
        let c0 = cell(strip, 0), c1 = cell(strip, 1), c2 = cell(strip, 2), c3 = cell(strip, 3)
        XCTAssertGreaterThan(c0[0], 200); XCTAssertLessThan(c0[2], 40, "つなぎ目の前: 赤")
        XCTAssertGreaterThan(c1[2], 200); XCTAssertLessThan(c1[0], 40, "クリップの頭: 青")
        XCTAssertGreaterThan(c2[2], 200, "クリップの最後のコマ: 青")
        XCTAssertLessThan(c3.max()!, 20, "終わりの後は背景の黒")
    }

    func testMissingFrameBeforeHeadIsAPlaceholderNotTheBackground() throws {
        let red = try png("r2", r: 1, g: 0, b: 0)
        var p = Project(); p.width = 160; p.height = 90; p.fps = 30; p.bg = "#000000"; p.characters = []
        var t0 = Track(name: "L0"); t0.clips = [image("red", red, start: 0, duration: 2)]
        p.tracks = [t0]
        let times = try XCTUnwrap(DragNeighborFrames.times(start: 0, end: 2, rate: p.frameRate))
        let strip = try XCTUnwrap(DragNeighborFrames.strip(project: p, assets: RenderAssets(), times: times))
        let c0 = cell(strip, 0)
        XCTAssertGreaterThan(c0.max()!, 30, "空の印(暗い灰色)で、描いた黒とは区別できる")
        XCTAssertLessThan(c0.max()!, 80)
        XCTAssertGreaterThan(cell(strip, 1)[0], 200)
    }

    func testStripCostAt1080p() throws {
        let red = try png("r3", r: 1, g: 0.5, b: 0)
        var p = Project(); p.width = 1920; p.height = 1080; p.fps = 60; p.characters = []
        var t0 = Track(name: "L0"); t0.clips = [image("a", red, start: 0, duration: 2), image("b", red, start: 2, duration: 2)]
        p.tracks = [t0]
        let times = try XCTUnwrap(DragNeighborFrames.times(start: 2, end: 4, rate: p.frameRate))
        let a = RenderAssets()
        _ = DragNeighborFrames.strip(project: p, assets: a, times: times)
        let n = 5
        let t0c = CFAbsoluteTimeGetCurrent()
        for _ in 0..<n { XCTAssertNotNil(DragNeighborFrames.strip(project: p, assets: a, times: times)) }
        print("[DragNeighborFrames] 1920x1080 strip (4 frames): \(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - t0c) * 1000 / Double(n))) ms/strip")
    }
}
