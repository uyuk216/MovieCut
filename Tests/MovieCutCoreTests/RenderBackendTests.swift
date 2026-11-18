import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import MovieCutCore

/// #77 Metal レンダリング: バックエンドの解決・フォールバックと、従来経路との画素同一性。
/// 同一性の数値(差分画素数・最大差・平均差)はテスト失敗時にも分かるよう、差分を出力する。
final class RenderBackendTests: XCTestCase {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("render-backend-tests-\(UUID().uuidString)")
    override func setUpWithError() throws { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    // MARK: バックエンド解決とフォールバック

    func testLegacyAlwaysResolvesToLegacyAndSharedContext() {
        let provider = RenderContextProvider.shared
        XCTAssertEqual(provider.resolvedBackend(for: .legacy), .legacy)
        // 従来経路は従来のグローバル CIContext そのもの(同一オブジェクト = 従来と完全に同じ描画)
        XCTAssertTrue(provider.context(for: .legacy) === ciContext)
        XCTAssertTrue(provider.legacyContext === ciContext)
    }

    func testMetalResolutionMatchesAvailability() {
        let provider = RenderContextProvider.shared
        // Metal が使える環境では .metal / .auto とも Metal、使えなければ従来へフォールバック
        let expected: RenderBackend = provider.isMetalAvailable ? .metal : .legacy
        XCTAssertEqual(provider.resolvedBackend(for: .metal), expected)
        XCTAssertEqual(provider.resolvedBackend(for: .auto), expected)
        // 利用可能性とデバイスの有無は一致する
        XCTAssertEqual(provider.isMetalAvailable, provider.metalDevice != nil)
        if provider.isMetalAvailable {
            XCTAssertNotNil(provider.metalDeviceName)
            XCTAssertTrue(provider.context(for: .metal) === provider.metalContext)
        } else {
            // フォールバック先は従来のコンテキスト
            XCTAssertTrue(provider.context(for: .metal) === ciContext)
        }
    }

    func testMetalContextIsSharedInstance() {
        let provider = RenderContextProvider.shared
        guard let a = provider.metalContext else {
            // Metal の無い環境では共有を確かめられない(フォールバックは上のテストで検証済み)
            return
        }
        XCTAssertTrue(a === provider.metalContext)
        XCTAssertTrue(a === provider.context(for: .auto))
    }

    func testExporterCarriesBackend() {
        var p = Project(); p.width = 64; p.height = 64
        XCTAssertEqual(Exporter(project: p, assets: RenderAssets()).renderBackend, .auto)
        XCTAssertEqual(Exporter(project: p, assets: RenderAssets(), renderBackend: .legacy).renderBackend, .legacy)
        XCTAssertEqual(Exporter(project: p, assets: RenderAssets(), renderBackend: .metal).renderBackend, .metal)
    }

    // MARK: 画素比較ユーティリティ自体

    private func solidImage(_ r: UInt8, _ g: UInt8, _ b: UInt8, size: Int = 16) -> CGImage {
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return ctx.makeImage()!
    }

    func testPixelComparisonIdenticalAndDifferent() {
        let a = solidImage(10, 20, 30)
        let same = try! XCTUnwrap(PixelComparison.compare(a, a))
        XCTAssertTrue(same.isIdentical)
        XCTAssertEqual(same.maxChannelDifference, 0)
        XCTAssertEqual(same.meanAbsoluteDifference, 0)
        let other = solidImage(11, 20, 30)
        let diff = try! XCTUnwrap(PixelComparison.compare(a, other))
        XCTAssertFalse(diff.isIdentical)
        XCTAssertEqual(diff.differingPixels, diff.totalPixels)
        XCTAssertEqual(diff.maxChannelDifference, 1)
        // 大きさが違えば比べられない
        XCTAssertNil(PixelComparison.compare(a, solidImage(0, 0, 0, size: 8)))
    }

    // MARK: 描画の同一性(従来経路 vs Metal 経路)

    private func writePNG(_ img: CGImage, _ name: String) throws -> String {
        let url = tmp.appendingPathComponent(name)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, img, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url.path
    }

    /// 市松模様の PNG(ぼかし・エフェクトで差が出やすい細かい絵)。
    private func checkerPNG(_ name: String) throws -> String {
        let cw = 32, ch = 18
        let c = CGContext(data: nil, width: cw, height: ch, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for y in 0..<ch { for x in 0..<cw {
            c.setFillColor(CGColor(gray: (x + y) % 2 == 0 ? 1 : 0.1, alpha: 1))
            c.fill(CGRect(x: x, y: y, width: 1, height: 1))
        } }
        return try writePNG(c.makeImage()!, name)
    }

    private func project(clips: [Clip], w: Int = 320, h: Int = 180) -> Project {
        var p = Project()
        p.width = w; p.height = h; p.bg = "#102030"; p.characters = []
        var tr = Track(name: "L1"); tr.clips = clips
        p.tracks = [tr]
        return p
    }

    private func imageClip(_ path: String) -> Clip {
        var c = Clip(); c.type = .image; c.start = 0; c.duration = 2; c.src = path
        c.x = 0.5; c.y = 0.5; c.scale = 3
        return c
    }

    private func render(_ p: Project, _ backend: RenderBackend) throws -> CGImage {
        try XCTUnwrap(Renderer(project: p, assets: RenderAssets(), backend: backend).renderImage(t: 0.5))
    }

    /// 差分を検証し、数値を必ずログへ出す(同一性の定量報告用)。
    private func assertSamePixels(_ legacy: CGImage, _ metal: CGImage, _ label: String,
                                  file: StaticString = #filePath, line: UInt = #line) throws {
        let d = try XCTUnwrap(PixelComparison.compare(legacy, metal), file: file, line: line)
        print("[RenderBackend] \(label): differing=\(d.differingPixels)/\(d.totalPixels) "
            + "(\(String(format: "%.4f", d.differingFraction * 100))%) maxDiff=\(d.maxChannelDifference) "
            + "meanDiff=\(String(format: "%.5f", d.meanAbsoluteDifference)) metalAvailable=\(RenderContextProvider.shared.isMetalAvailable)")
        // GPU の浮動小数の丸めで ±1 の差が出る場合だけ許す。それ以上の差は描画が変わった証拠。
        XCTAssertLessThanOrEqual(d.maxChannelDifference, 1, "\(label): 最大チャンネル差が 1 を超えた", file: file, line: line)
        XCTAssertLessThanOrEqual(d.differingFraction, 0.02, "\(label): 差分画素が 2% を超えた", file: file, line: line)
        XCTAssertLessThanOrEqual(d.meanAbsoluteDifference, 0.01, "\(label): 平均差が大きい", file: file, line: line)
    }

    func testPlainFrameIsByteIdenticalAcrossBackends() throws {
        // Core Image を通らない絵(画像 + 文字 + 背景)は、合成が従来どおり CGContext なので完全一致するはず
        let path = try checkerPNG("plain.png")
        var text = Clip(); text.type = .text; text.start = 0; text.duration = 2
        text.text = "同一性"; text.fontSize = 42; text.x = 0.5; text.y = 0.5
        let p = project(clips: [imageClip(path), text])
        let legacy = try render(p, .legacy)
        let d = try XCTUnwrap(PixelComparison.compare(legacy, try render(p, .metal)))
        XCTAssertTrue(d.isIdentical, "CI を通らないフレームは完全一致のはず: \(d)")
        let dAuto = try XCTUnwrap(PixelComparison.compare(legacy, try render(p, .auto)))
        XCTAssertTrue(dAuto.isIdentical)
    }

    func testBlurredClipMatchesAcrossBackends() throws {
        // クリップぼかし経路(ciCtx.createCGImage)
        let path = try checkerPNG("blur.png")
        var c = imageClip(path); c.blur = 6
        let p = project(clips: [c])
        try assertSamePixels(try render(p, .legacy), try render(p, .metal), "clip-blur")
    }

    func testEffectedClipMatchesAcrossBackends() throws {
        // エフェクト経路(EffectPipeline.makeImage(context:)): ぼかし + 明るさ + 彩度
        let path = try checkerPNG("fx.png")
        var c = imageClip(path)
        c.effects = [Effect(.gaussianBlur), Effect(.brightness), Effect(.saturation)]
        c.effects[0].params["radius"] = 4
        c.effects[1].params["amount"] = 0.15
        c.effects[2].params["amount"] = 1.4
        let p = project(clips: [c])
        try assertSamePixels(try render(p, .legacy), try render(p, .metal), "effects")
    }

    func testBlurRegionMatchesAcrossBackends() throws {
        // ぼかし範囲経路(2 つ目の ciCtx 利用箇所)
        var bases: [Clip] = []
        for col in 0..<106 {
            var sc = Clip(); sc.type = .shape; sc.start = 0; sc.duration = 2
            sc.x = (Double(col) * 3 + 1.5) / 320; sc.y = 0.5; sc.w = 3.0 / 320; sc.h = 1
            sc.figure = Figure(kind: "rect", fill: col % 2 == 0 ? "#ffffff" : "#000000")
            bases.append(sc)
        }
        var b = Clip(); b.type = .blur; b.start = 0; b.duration = 2
        b.x = 0.5; b.y = 0.5; b.w = 0.5; b.h = 0.5; b.strength = 8
        let p = project(clips: bases + [b])
        try assertSamePixels(try render(p, .legacy), try render(p, .metal), "blur-region")
    }

    func testAdjustmentLayerMatchesAcrossBackends() throws {
        // 調整レイヤー経路(EffectPipeline.makeImage の canvas 版)
        let path = try checkerPNG("adj.png")
        var adj = Clip(); adj.type = .adjustment; adj.start = 0; adj.duration = 2
        adj.effects = [Effect(.brightness)]
        adj.effects[0].params["amount"] = 0.2
        var p = project(clips: [imageClip(path)])
        var tr = Track(name: "L2"); tr.clips = [adj]
        p.tracks.append(tr)
        try assertSamePixels(try render(p, .legacy), try render(p, .metal), "adjustment")
    }
}
