import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import MovieCutCore

/// ブレンドモード: ファイル形式の往復と、描画(乗算)の効き。
final class BlendModeTests: XCTestCase {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("blend-tests-\(UUID().uuidString)")
    override func setUpWithError() throws { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func testRoundTrip() throws {
        var c = Clip(); c.blendMode = .multiply
        let data = try JSONEncoder().encode(c)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"blendMode\":\"multiply\""), json)
        XCTAssertEqual(try JSONDecoder().decode(Clip.self, from: data).blendMode, .multiply)

        // 未設定なら書かない
        let plain = try JSONEncoder().encode(Clip())
        XCTAssertFalse(String(data: plain, encoding: .utf8)?.contains("blendMode") ?? true)

        // 知らない名前は捨てずに extra へ(値は blendMode にならない)
        let unknown = try JSONDecoder().decode(Clip.self, from: Data(#"{"id":"x","type":"image","blendMode":"weird"}"#.utf8))
        XCTAssertNil(unknown.blendMode)
        XCTAssertEqual(unknown.extra["blendMode"], .string("weird"))
        let rewritten = try JSONEncoder().encode(unknown)
        XCTAssertTrue(String(data: rewritten, encoding: .utf8)?.contains("\"blendMode\":\"weird\"") ?? false)
    }

    func testAllCasesHaveLabelsAndMapping() {
        XCTAssertEqual(ClipBlendMode.allCases.count, 16)
        for m in ClipBlendMode.allCases { XCTAssertFalse(m.label.isEmpty) }
        XCTAssertEqual(ClipBlendMode.multiply.cgBlendMode, .multiply)
        XCTAssertEqual(ClipBlendMode.screen.cgBlendMode, .screen)
        XCTAssertEqual(ClipBlendMode.plusLighter.cgBlendMode, .plusLighter)
    }

    // MARK: 描画

    private func solidPNG(_ name: String, r: UInt8, g: UInt8, b: UInt8, size: Int = 256) throws -> String {
        let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1))
        c.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let url = tmp.appendingPathComponent(name)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, c.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url.path
    }

    private func imageClip(_ path: String, blend: ClipBlendMode? = nil) -> Clip {
        var c = Clip(); c.type = .image; c.src = path; c.start = 0; c.duration = 2
        c.x = 0.5; c.y = 0.5; c.scale = 1; c.opacity = 1; c.blendMode = blend
        return c
    }

    private func centerRGB(_ p: Project) throws -> (Int, Int, Int) {
        let img = try XCTUnwrap(Renderer(project: p, assets: RenderAssets()).renderImage(t: 0.5))
        var d = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let ctx = CGContext(data: &d, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        let i = ((img.height / 2) * img.width + img.width / 2) * 4
        return (Int(d[i]), Int(d[i + 1]), Int(d[i + 2]))
    }

    private func stackedProject(topBlend: ClipBlendMode?) throws -> Project {
        var p = Project(); p.width = 64; p.height = 64; p.bg = "#000000"; p.characters = []
        var bottom = Track(name: "下"); bottom.clips = [imageClip(try solidPNG("red.png", r: 255, g: 0, b: 0))]
        var top = Track(name: "上"); top.clips = [imageClip(try solidPNG("gray.png", r: 128, g: 128, b: 128), blend: topBlend)]
        p.tracks = [bottom, top]
        return p
    }

    func testRenderMultiply() throws {
        // 通常: 上の灰色がそのまま出る
        let normal = try centerRGB(stackedProject(topBlend: nil))
        XCTAssertEqual(normal.0, 128); XCTAssertEqual(normal.1, 128); XCTAssertEqual(normal.2, 128)
        // 乗算: 赤 × 灰色 = (128, 0, 0)
        let mul = try centerRGB(stackedProject(topBlend: .multiply))
        XCTAssertEqual(mul.0, 128, accuracy: 2); XCTAssertEqual(mul.1, 0, accuracy: 2); XCTAssertEqual(mul.2, 0, accuracy: 2)
        // スクリーン: 赤 ∪ 灰色 = (255, 128, 128)
        let scr = try centerRGB(stackedProject(topBlend: .screen))
        XCTAssertEqual(scr.0, 255, accuracy: 2); XCTAssertEqual(scr.1, 128, accuracy: 2); XCTAssertEqual(scr.2, 128, accuracy: 2)
    }
}
