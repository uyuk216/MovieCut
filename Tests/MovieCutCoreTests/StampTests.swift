import XCTest
import CoreGraphics
@testable import MovieCutCore

/// スタンプ(絵文字): 組み込み 24 種、文字クリップとして置く、カラー字形で描ける(黒い背景に色が出る)。
final class StampTests: XCTestCase {
    func testCatalogHasTwentyFourDistinctStamps() {
        XCTAssertEqual(StampCatalog.items.count, 24)
        XCTAssertEqual(Set(StampCatalog.items.map(\.emoji)).count, 24)
        XCTAssertTrue(StampCatalog.isStamp("😀"))
        XCTAssertFalse(StampCatalog.isStamp("abc"))
    }

    func testMakeStampClipIsPlainTextClip() {
        let c = ClipEditing.makeStampClip("🎉", at: 1.25)
        XCTAssertEqual(c.type, .text)
        XCTAssertEqual(c.start, 1.25)
        XCTAssertEqual(c.duration, StampCatalog.defaultDuration)
        XCTAssertEqual(c.text, "🎉")
        XCTAssertEqual(c.fontSize, StampCatalog.fontSize)
        XCTAssertNil(c.textStyle)
        // 保存の形: スタンプ専用の項目は増えない(文字クリップと同じ)
        let data = try! JSONEncoder().encode(c)
        let s = String(data: data, encoding: .utf8)!
        XCTAssertFalse(s.contains("stamp"))
    }

    /// カラー字形は輪郭が取れないので、CoreText で直接描く。黄色い顔が出ることを確かめる。
    func testStampDrawsColourGlyphs() throws {
        var tr = Track(name: "L1")
        tr.clips = [ClipEditing.makeStampClip("😀", at: 0)]
        var p = Project(); p.width = 320; p.height = 240; p.bg = "#000000"; p.tracks = [tr]; p.characters = []
        let img = try XCTUnwrap(Renderer(project: p, assets: RenderAssets()).renderImage(t: 1))
        var d = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let ctx = CGContext(data: &d, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        var colourful = 0
        for i in stride(from: 0, to: d.count, by: 4) {
            let r = Int(d[i]), g = Int(d[i + 1]), b = Int(d[i + 2])
            if r > 150, g > 120, b < 110 { colourful += 1 }
        }
        XCTAssertGreaterThan(colourful, 500, "カラー字形の絵文字が描かれる")
    }
}
