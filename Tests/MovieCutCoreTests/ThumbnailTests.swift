import XCTest
import CoreGraphics
import ImageIO
@testable import MovieCutCore

/// サムネイル画像(1280×720): 縦横比を保って中に収め、余白は背景色。PNG / JPEG で書けて、読み直すと 1280×720。
final class ThumbnailTests: XCTestCase {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("thumb-tests-\(UUID().uuidString)")
    override func setUpWithError() throws { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func testFitKeepsAspectAndCenters() {
        XCTAssertEqual(ThumbnailExporter.fittedRect(source: CGSize(width: 1920, height: 1080)), CGRect(x: 0, y: 0, width: 1280, height: 720))
        // 9:16 の縦動画は、高さいっぱいで中央に
        let v = ThumbnailExporter.fittedRect(source: CGSize(width: 1080, height: 1920))
        XCTAssertEqual(v.height, 720, accuracy: 1e-9)
        XCTAssertEqual(v.width, 405, accuracy: 1e-9)
        XCTAssertEqual(v.minX, (1280 - 405) / 2, accuracy: 1e-9)
        // 4:3 は左右に余白
        let s = ThumbnailExporter.fittedRect(source: CGSize(width: 400, height: 300))
        XCTAssertEqual(s.width, 960, accuracy: 1e-9)
        XCTAssertEqual(s.minX, 160, accuracy: 1e-9)
    }

    /// 画素を RGBA で読む(左上原点)
    func pixels(_ img: CGImage) -> [UInt8] {
        var d = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let ctx = CGContext(data: &d, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return d
    }

    func testComposeIsOpaque1280x720WithBackgroundAroundTheFrame() throws {
        // 縦長の赤い 4×8 の画像を、青の背景の 1280×720 に収める(中央は赤、左右の余白は青)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let src = try XCTUnwrap(CGContext(data: nil, width: 4, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        src.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        src.fill(CGRect(x: 0, y: 0, width: 4, height: 8))
        let frame = try XCTUnwrap(src.makeImage())
        let blue = CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
        let out = try XCTUnwrap(ThumbnailExporter.compose(frame, background: blue))
        XCTAssertEqual(out.width, 1280)
        XCTAssertEqual(out.height, 720)
        let d = pixels(out)
        func px(_ x: Int, _ y: Int) -> (Int, Int, Int) { let i = (y * 1280 + x) * 4; return (Int(d[i]), Int(d[i + 1]), Int(d[i + 2])) }
        XCTAssertEqual(px(640, 360).0, 255, "中央は赤")
        XCTAssertEqual(px(5, 5).2, 255, "左上の余白は青")
        XCTAssertEqual(px(1275, 715).2, 255, "右下の余白も青")
    }

    func testWritesPNGAndJPEGAt1280x720() throws {
        var p = Project()
        p.width = 640; p.height = 360; p.bg = "#102030"
        var c = ClipEditing.makeShapeClip(.rect, at: 0, project: p)
        c.duration = 2; c.w = 0.5; c.h = 0.5; c.figure = Figure(kind: nil, fill: "#ff0000")
        var tr = Track(name: "L1"); tr.clips = [c]; p.tracks = [tr]
        for ext in ["png", "jpg"] {
            let url = tmp.appendingPathComponent("thumb.\(ext)")
            try ThumbnailExporter.write(project: p, at: 0.5, format: StillFormat(pathExtension: ext) ?? .png, to: url)
            let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let img = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
            XCTAssertEqual(img.width, 1280, ext)
            XCTAssertEqual(img.height, 720, ext)
        }
    }
}
