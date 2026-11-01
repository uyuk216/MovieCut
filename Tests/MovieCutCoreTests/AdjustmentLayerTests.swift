import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import MovieCutCore

/// 調整レイヤー(クリップの種類 adjustment): 下に描いてある全部の合成結果に、自分のエフェクトを一度かける(画素で確認)。
final class AdjustmentLayerTests: XCTestCase {
    struct Px {
        let w: Int
        var d: [UInt8]
        func rgb(_ x: Int, _ y: Int) -> [Int] { let i = (y * w + x) * 4; return [Int(d[i]), Int(d[i + 1]), Int(d[i + 2])] }
    }

    func pixels(_ img: CGImage) -> Px {
        var d = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let c = CGContext(data: &d, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return Px(w: img.width, d: d)
    }

    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("adjust-tests-\(UUID().uuidString)")
    override func setUpWithError() throws { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    /// 純色(赤)の 40×40 PNG
    func redPNG() throws -> String {
        let c = CGContext(data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        c.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        let url = tmp.appendingPathComponent("red.png")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(c.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url.path
    }

    /// 200×200・背景黒。下のレイヤーに赤い画像を全面に。`adjustment` を上のレイヤー(below = true なら下)に置く。
    func project(_ path: String, adjustment: Clip?, below: Bool = false, imageEffects: [Effect] = []) -> Project {
        var img = Clip(); img.id = "i"; img.type = .image; img.src = path; img.start = 0; img.duration = 4
        img.x = 0.5; img.y = 0.5; img.scale = 1; img.effects = imageEffects
        var p = Project(); p.width = 200; p.height = 200; p.bg = "#000000"; p.characters = []
        var base = Track(name: "素材"); base.clips = [img]
        p.tracks = [base]
        if var a = adjustment {
            a.id = "a"
            var top = Track(name: "調整"); top.clips = [a]
            p.tracks = below ? [top, base] : [base, top]
        }
        return p
    }

    func adjustment(start: Double = 0, duration: Double = 4, opacity: Double? = nil, effects: [Effect] = [Effect(.mono)]) -> Clip {
        var a = Clip(); a.type = .adjustment; a.start = start; a.duration = duration; a.opacity = opacity; a.effects = effects
        return a
    }

    func render(_ p: Project, t: Double = 1) throws -> Px {
        pixels(try XCTUnwrap(Renderer(project: p, assets: RenderAssets()).renderImage(t: t)))
    }

    func center(_ px: Px) -> [Int] { px.rgb(100, 100) }

    func testAdjustmentOnTopGrayscalesWhatIsBelow() throws {
        let path = try redPNG()
        let plainRed = center(try render(project(path, adjustment: nil)))
        XCTAssertGreaterThan(plainRed[0], 200); XCTAssertLessThan(plainRed[1], 30, "素材は赤いまま")
        let mono = center(try render(project(path, adjustment: adjustment())))
        XCTAssertEqual(mono[0], mono[1], accuracy: 3); XCTAssertEqual(mono[1], mono[2], accuracy: 3, "白黒になる")
        // 同じエフェクトを素材に直接かけた絵と一致する(調整レイヤー = 下の合成結果への 1 回がけ)
        let direct = center(try render(project(path, adjustment: nil, imageEffects: [Effect(.mono)])))
        for k in 0..<3 { XCTAssertEqual(mono[k], direct[k], accuracy: 3) }
    }

    func testAdjustmentBelowTheImageChangesNothing() throws {
        let path = try redPNG()
        let plain = try render(project(path, adjustment: nil))
        let below = try render(project(path, adjustment: adjustment(), below: true))
        XCTAssertEqual(plain.d, below.d, "下にあるレイヤーには効かない")
    }

    func testAdjustmentOutsideItsTimeRangeChangesNothing() throws {
        let path = try redPNG()
        let plain = try render(project(path, adjustment: nil))
        let later = try render(project(path, adjustment: adjustment(start: 2, duration: 1)), t: 1)
        XCTAssertEqual(plain.d, later.d)
        let during = try render(project(path, adjustment: adjustment(start: 2, duration: 1)), t: 2.5)
        XCTAssertNotEqual(plain.d, during.d)
    }

    func testOpacityZeroDoesNothingAndHalfMixes() throws {
        let path = try redPNG()
        let plain = try render(project(path, adjustment: nil))
        XCTAssertEqual(plain.d, try render(project(path, adjustment: adjustment(opacity: 0))).d, "不透明度 0 は何もしない")
        let full = center(try render(project(path, adjustment: adjustment(opacity: 1))))
        let half = center(try render(project(path, adjustment: adjustment(opacity: 0.5))))
        let rp = center(plain)
        for k in 0..<3 { XCTAssertEqual(Double(half[k]), (Double(rp[k]) + Double(full[k])) / 2, accuracy: 4, "元の絵と 50% で混ざる") }
    }

    func testClipFromEditingHasNoSourceAndNoOptionalFields() throws {
        let c = ClipEditing.makeAdjustmentClip(at: 2, project: Project())
        XCTAssertEqual(c.type, .adjustment); XCTAssertEqual(c.start, 2); XCTAssertEqual(c.duration, 3)
        XCTAssertNil(c.src); XCTAssertTrue(c.effects.isEmpty)
        XCTAssertNil(c.opacity, "既定の値は書かない")
        XCTAssertTrue(ClipType.known.contains(.adjustment))
        // 保存しても追加の項目は増えない(type・start・duration・id だけ)
        let json = String(decoding: try JSONEncoder().encode(c), as: UTF8.self)
        XCTAssertTrue(json.contains("\"adjustment\""))
        XCTAssertFalse(json.contains("opacity"))
        XCTAssertFalse(json.contains("src"))
        XCTAssertEqual(try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(c)), c)
    }

    func testKeyframeTargetsAreOpacityAndEffects() {
        let a = adjustment(effects: [Effect(.mono)])
        XCTAssertTrue(Animation.keys(for: a).contains("opacity"))
        XCTAssertFalse(Animation.keys(for: a).contains("x"), "位置や大きさは持たない")
    }
}
