import XCTest
import CoreGraphics
@testable import MovieCutCore

/// ぼかし範囲クリップの「モザイク」方式: 範囲の中だけ変わり、ブロックの大きさが効き、既定(ぼかし)と書式が変わらないこと。
final class BlurRegionMosaicTests: XCTestCase {
    func project(_ clips: [Clip]) -> Project {
        var p = Project(); p.width = 320; p.height = 180; p.fps = 30
        p.tracks = clips.map { c in var t = Track(); t.clips = [c]; return t }
        return p
    }

    func pixels(_ img: CGImage) -> [UInt8] {
        var d = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let c = CGContext(data: &d, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return d
    }

    func region(mode: String?, size: Double? = nil) throws -> [UInt8] {
        // 背景は白い図形(素材ファイルを使わずに済ませる)
        // 白と黒の細い縦縞(3 px おき)。細かい絵にして、モザイク・ぼかしで必ず変わるようにする
        var bases: [Clip] = []
        for col in 0..<106 {
            var s = Clip(); s.type = .shape; s.start = 0; s.duration = 2
            s.x = (Double(col) * 3 + 1.5) / 320; s.y = 0.5; s.w = 3.0 / 320; s.h = 1
            s.figure = Figure(kind: "rect", fill: col % 2 == 0 ? "#ffffff" : "#000000")
            bases.append(s)
        }
        var b = Clip(); b.type = .blur; b.start = 0; b.duration = 2; b.x = 0.5; b.y = 0.5; b.w = 0.5; b.h = 0.5
        b.strength = 8; b.blurMode = mode; b.mosaicSize = size
        let withBlur = try XCTUnwrap(Renderer(project: project(bases + [b]), assets: RenderAssets()).renderImage(t: 0.5))
        return pixels(withBlur)
    }

    func testMosaicDiffersFromBlurAndDefaultIsBlur() throws {
        // 既定(blurMode 無し)と "blur" は同じ絵、"mosaic" は別の絵
        let none = try region(mode: nil), blur = try region(mode: "blur"), mosaic = try region(mode: "mosaic", size: 24)
        XCTAssertEqual(none, blur)
        XCTAssertNotEqual(none, mosaic)
    }

    func testMosaicSizeChangesTheResult() throws {
        XCTAssertNotEqual(try region(mode: "mosaic", size: 8), try region(mode: "mosaic", size: 40))
    }

    func testFileRoundTripKeepsDefaultsOutOfTheFile() throws {
        // 既定の設定は書かない(古いファイルと同じ形のまま)
        var plain = Clip(); plain.type = .blur; plain.id = "b"
        let encoded = try JSONEncoder().encode(plain)
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(text.contains("blurMode"))
        XCTAssertFalse(text.contains("mosaicSize"))
        // 設定すると書く・読み直すと同じ値
        var m = plain; m.blurMode = "mosaic"; m.mosaicSize = 20
        let back = try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(m))
        XCTAssertEqual(back.blurMode, "mosaic")
        XCTAssertEqual(back.mosaicSizeOrDefault, 20)
        XCTAssertEqual(Clip().blurModeOrDefault, "blur")
        XCTAssertEqual(Clip().mosaicSizeOrDefault, 12)
    }
}
