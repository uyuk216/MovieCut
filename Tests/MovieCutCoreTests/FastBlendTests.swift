import XCTest
import CoreGraphics
@testable import MovieCutCore

/// 不透明度つき画像の直接合成(FastBlend)が、CoreGraphics の描画と ±1/255 以内で同じ画素になること。
final class FastBlendTests: XCTestCase {
    private func makeImage(w: Int, h: Int) -> CGImage {
        let c = Renderer.makeContext(width: w, height: h)!
        for y in 0..<h {
            for x in 0..<w {
                c.setFillColor(CGColor(srgbRed: CGFloat(x) / CGFloat(w), green: CGFloat(y) / CGFloat(h), blue: 0.4, alpha: x % 5 == 0 ? 0.5 : 1))
                c.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return c.makeImage()!
    }

    private func render(_ p: Project, assets: RenderAssets) -> [UInt8] {
        let img = Renderer(project: p, assets: assets).renderImage(t: 0.5)!
        let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: img.width * img.height * 4))
    }

    func testFadedImageMatchesCoreGraphics() throws {
        let png = FileManager.default.temporaryDirectory.appendingPathComponent("fb-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: png) }
        let src = makeImage(w: 64, h: 36)
        let dest = CGImageDestinationCreateWithURL(png as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, src, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        for (opacity, x, scale) in [(0.6, 0.5, 1.0), (0.3, 0.5003, 0.93), (0.99, 0.5, 1.0), (0.5, 0.4, 0.5)] {
            let json = """
            {"width":64,"height":36,"fps":30,"bg":"#102030","codec":"h264","characters":[],"tracks":[{"id":"t","name":"x","clips":[
            {"id":"a","type":"image","src":"\(png.path)","start":0,"duration":2,"offset":0,"x":\(x),"y":0.5,"scale":\(scale),"opacity":\(opacity)}]}]}
            """
            let p = try JSONDecoder().decode(Project.self, from: Data(json.utf8))
            FastBlend.disabled = true
            let ref = render(p, assets: RenderAssets())
            FastBlend.disabled = false
            let got = render(p, assets: RenderAssets())
            let maxDiff = zip(ref, got).map { abs(Int($0) - Int($1)) }.max() ?? 0
            XCTAssertLessThanOrEqual(maxDiff, 1, "opacity \(opacity) x \(x) scale \(scale)")
        }
    }
}
