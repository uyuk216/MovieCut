import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import MovieCutCore

/// 動く立ち絵(アニメーション画像): コマの選び方(純粋関数)・実ファイルのタイミング読み取りとコマ取得・描画への組み込み。
final class AnimatedTachieTests: XCTestCase {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("animated-tachie-\(UUID().uuidString)")
    override func setUpWithError() throws { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    // MARK: ヘルパー

    func solid(_ c: (UInt8, UInt8, UInt8), w: Int = 40, h: Int = 40) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: CGFloat(c.0) / 255, green: CGFloat(c.1) / 255, blue: CGFloat(c.2) / 255, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    /// 赤・緑・青の 3 コマ GIF(遅延は既定 0.1 / 0.2 / 0.3 秒)。
    @discardableResult
    func writeGIF(_ name: String, delays: [Double] = [0.1, 0.2, 0.3], loop: Int = 0) throws -> String {
        let colors: [(UInt8, UInt8, UInt8)] = [(255, 0, 0), (0, 255, 0), (0, 0, 255)]
        let url = tmp.appendingPathComponent(name)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, delays.count, nil))
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: loop]] as CFDictionary)
        for (i, d) in delays.enumerated() {
            let props = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: d, kCGImagePropertyGIFUnclampedDelayTime: d]]
            CGImageDestinationAddImage(dest, solid(colors[i % colors.count]), props as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url.path
    }

    func writePNG(_ name: String, _ c: (UInt8, UInt8, UInt8)) throws -> String {
        let url = tmp.appendingPathComponent(name)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, solid(c), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url.path
    }

    func pixel(_ img: CGImage, _ x: Int, _ y: Int) -> (Int, Int, Int) {
        var d = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let c = CGContext(data: &d, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        let i = (y * img.width + x) * 4
        return (Int(d[i]), Int(d[i + 1]), Int(d[i + 2]))
    }

    /// 色が「どの原色寄りか」で判定(圧縮・色空間の誤差を許す)。
    func dominant(_ p: (Int, Int, Int)) -> String { p.0 > 150 ? "R" : p.1 > 150 ? "G" : p.2 > 150 ? "B" : "?" }

    // MARK: AnimatedImageTiming.frameIndex

    func testFrameIndexBoundariesAndMonotonic() {
        let t = AnimatedImageTiming(frameCount: 3, delays: [0.1, 0.2, 0.3])
        XCTAssertEqual(t.totalDuration ?? 0, 0.6, accuracy: 1e-9)
        XCTAssertEqual(t.frameIndex(at: 0), 0)
        XCTAssertEqual(t.frameIndex(at: 0.0999), 0)
        XCTAssertEqual(t.frameIndex(at: 0.1), 1, "開始時刻ちょうどは次のコマ")
        XCTAssertEqual(t.frameIndex(at: 0.2999), 1)
        XCTAssertEqual(t.frameIndex(at: 0.3), 2)
        XCTAssertEqual(t.frameIndex(at: 0.5999), 2)
        var last = 0
        for i in 0..<60 { let k = t.frameIndex(at: Double(i) * 0.01); XCTAssertGreaterThanOrEqual(k, last); last = k }
    }

    func testFrameIndexInfiniteLoopWraps() {
        let t = AnimatedImageTiming(frameCount: 3, delays: [0.1, 0.2, 0.3], loopCount: 0)
        XCTAssertEqual(t.frameIndex(at: 0.6), 0)
        XCTAssertEqual(t.frameIndex(at: 0.75), 1)
        XCTAssertEqual(t.frameIndex(at: 6.0 + 0.45), 2)
        XCTAssertEqual(t.frameIndex(at: 1_000_000), t.frameIndex(at: 1_000_000.0.truncatingRemainder(dividingBy: 0.6)))
    }

    func testFrameIndexFiniteLoopStopsAtLastFrame() {
        let t = AnimatedImageTiming(frameCount: 3, delays: [0.1, 0.2, 0.3], loopCount: 2)
        XCTAssertEqual(t.frameIndex(at: 0.7), 1, "2 周目の途中は動く")
        XCTAssertEqual(t.frameIndex(at: 1.19), 2)
        XCTAssertEqual(t.frameIndex(at: 1.2), 2, "回数を使い切ったら最後のコマ")
        XCTAssertEqual(t.frameIndex(at: 100), 2)
    }

    func testFrameIndexClampsTinyDelaysAndHandlesNegativeAndSingleFrame() {
        // 0 遅延は 0.02 秒に丸める(合計は丸め前で判定: 0 のコマだけなら静止画扱い)
        let t = AnimatedImageTiming(frameCount: 3, delays: [0, 0.5, 0], loopCount: 0)
        XCTAssertEqual(t.frameIndex(at: 0.019), 0)
        XCTAssertEqual(t.frameIndex(at: 0.02), 1)
        XCTAssertEqual(t.frameIndex(at: 0.52), 2)
        XCTAssertEqual(t.frameIndex(at: 0.54), 0, "丸めた 0.02 + 0.5 + 0.02 で 1 周")
        XCTAssertEqual(t.frameIndex(at: -3), 0)
        XCTAssertEqual(t.frameIndex(at: .nan), 0)
        let one = AnimatedImageTiming(frameCount: 1, delays: [0.1])
        XCTAssertEqual(one.frameIndex(at: 5), 0)
        XCTAssertFalse(one.isAnimated)
        let zero = AnimatedImageTiming(frameCount: 2, delays: [0, 0])
        XCTAssertNil(zero.totalDuration)
        XCTAssertEqual(zero.frameIndex(at: 5), 0)
    }

    // MARK: 実ファイル

    func testReadsTimingFromGIF() throws {
        let p = try writeGIF("a.gif", delays: [0.1, 0.2, 0.3], loop: 0)
        let t = try XCTUnwrap(AnimatedImage.timing(atPath: p))
        XCTAssertEqual(t.frameCount, 3)
        XCTAssertEqual(t.delays.count, 3)
        for (a, b) in zip(t.delays, [0.1, 0.2, 0.3]) { XCTAssertEqual(a, b, accuracy: 0.011) }
        XCTAssertEqual(t.loopCount, 0)
        let finite = try XCTUnwrap(AnimatedImage.timing(atPath: try writeGIF("b.gif", loop: 3)))
        XCTAssertEqual(finite.loopCount, 3)
    }

    func testStillMissingAndBrokenFilesHaveNoTiming() throws {
        XCTAssertNil(AnimatedImage.timing(atPath: try writePNG("s.png", (1, 2, 3))))
        XCTAssertNil(AnimatedImage.timing(atPath: tmp.appendingPathComponent("none.gif").path))
        let broken = tmp.appendingPathComponent("broken.gif")
        try Data("not an image".utf8).write(to: broken)
        XCTAssertNil(AnimatedImage.timing(atPath: broken.path))
        let single = try writeGIF("one.gif", delays: [0.1])
        XCTAssertNil(AnimatedImage.timing(atPath: single), "1 コマの GIF は静止画扱い")
    }

    func testRenderAssetsReturnsDifferentFramesAndFrameZeroMatchesImageAt() throws {
        let gif = try writeGIF("a.gif")
        let assets = RenderAssets()
        let t = try XCTUnwrap(assets.animationTiming(at: gif))
        XCTAssertEqual(t.frameCount, 3)
        let f0 = try XCTUnwrap(assets.image(at: gif, frameIndex: 0))
        let f1 = try XCTUnwrap(assets.image(at: gif, frameIndex: 1))
        let f2 = try XCTUnwrap(assets.image(at: gif, frameIndex: 2))
        XCTAssertEqual([f0, f1, f2].map { dominant(pixel($0, 20, 20)) }, ["R", "G", "B"])
        XCTAssertTrue(assets.image(at: gif) === f0, "0 コマ目は image(at:) と同じキャッシュ")
        XCTAssertTrue(assets.image(at: gif, frameIndex: 1) === f1, "コマごとにキャッシュ")
        XCTAssertNil(assets.image(at: gif, frameIndex: 3), "範囲外は nil")
        XCTAssertEqual(dominant(pixel(try XCTUnwrap(assets.tachieImage(at: gif, elapsed: 0.15)), 20, 20)), "G")
        XCTAssertEqual(dominant(pixel(try XCTUnwrap(assets.tachieImage(at: gif, elapsed: 0.65)), 20, 20)), "R", "ループして戻る")
    }

    func testStillPNGHasNoTimingAndFrameZeroMatchesLegacy() throws {
        let png = try writePNG("s.png", (10, 200, 30))
        let assets = RenderAssets()
        XCTAssertNil(assets.animationTiming(at: png))
        XCTAssertNil(assets.animationTiming(at: png), "静止画の結果もキャッシュ")
        let legacy = try XCTUnwrap(assets.image(at: png))
        XCTAssertTrue(try XCTUnwrap(assets.image(at: png, frameIndex: 0)) === legacy)
        XCTAssertTrue(try XCTUnwrap(assets.tachieImage(at: png, elapsed: 12.3)) === legacy, "静止画は時刻に関係なく同じ画像")
        XCTAssertNil(assets.image(at: png, frameIndex: 1))
        XCTAssertNil(assets.tachieImage(at: tmp.appendingPathComponent("none.png").path, elapsed: 1))
    }

    // MARK: 描画統合

    func project(_ tachie: Tachie, start: Double = 0) -> Project {
        var p = Project()
        p.width = 120; p.height = 80; p.bg = "#000000"
        p.tachies = [tachie]
        var c = Clip(); c.id = "c1"; c.type = .tachie; c.tachieId = tachie.id; c.start = start; c.duration = 3; c.x = 0.5; c.y = 0.5
        var tr = Track(name: "L0"); tr.clips = [c]
        p.tracks = [tr]
        return p
    }

    func centerColor(_ p: Project, t: Double, assets: RenderAssets = RenderAssets()) throws -> String {
        let img = try XCTUnwrap(Renderer(project: p, assets: assets).renderImage(t: t))
        return dominant(pixel(img, img.width / 2, img.height / 2))
    }

    func testRenderChangesWithTimeForAnimatedImage() throws {
        let gif = try writeGIF("a.gif")
        var t = Tachie(name: "動く"); t.id = "t1"; t.imgClosed = gif
        let p = project(t)
        let assets = RenderAssets()
        XCTAssertEqual(try centerColor(p, t: 0.0, assets: assets), "R")
        XCTAssertEqual(try centerColor(p, t: 0.15, assets: assets), "G")
        XCTAssertEqual(try centerColor(p, t: 0.45, assets: assets), "B")
        XCTAssertEqual(try centerColor(p, t: 0.65, assets: assets), "R", "ループ")
        // クリップ内時刻: 開始が 1 秒のクリップは 1.0 秒が先頭コマ、開始前の負の時刻は 0 として扱う
        let shifted = project(t, start: 1)
        XCTAssertEqual(try centerColor(shifted, t: 1.0, assets: assets), "R")
        XCTAssertEqual(try centerColor(shifted, t: 1.15, assets: assets), "G")
        XCTAssertEqual(try centerColor(shifted, t: 1.45, assets: assets), "B")
    }

    func testRenderStillTachieIsUnchangedOverTime() throws {
        let png = try writePNG("s.png", (255, 0, 0))
        var t = Tachie(name: "静止"); t.id = "t1"; t.imgClosed = png
        let p = project(t)
        let assets = RenderAssets()
        let a = try XCTUnwrap(Renderer(project: p, assets: assets).renderImage(t: 0))
        let b = try XCTUnwrap(Renderer(project: p, assets: assets).renderImage(t: 2.2))
        XCTAssertEqual(pixel(a, 60, 40).0, pixel(b, 60, 40).0)
        XCTAssertEqual(dominant(pixel(b, 60, 40)), "R")
        XCTAssertEqual(try Renderer(project: p, assets: assets).tachieSize(p.tracks[0].clips[0], at: 0), try Renderer(project: p, assets: assets).tachieSize(p.tracks[0].clips[0], at: 2.2))
    }

    func testRigPartsAdvanceWithAnimatedPartAndKeepLegacyKeyForStills() throws {
        let gif = try writeGIF("part.gif")
        let base = try writePNG("base.png", (40, 40, 40))
        let cache = RigFrameCache()
        let f0 = try XCTUnwrap(cache.frame(paths: [base, gif], height: 40))
        XCTAssertEqual(dominant(pixel(f0, 20, 20)), "R")
        let f1 = try XCTUnwrap(cache.frame(paths: [base, gif], height: 40, frames: [0, 1]))
        XCTAssertEqual(dominant(pixel(f1, 20, 20)), "G")
        let f2 = try XCTUnwrap(cache.frame(paths: [base, gif], height: 40, frames: [0, 2]))
        XCTAssertEqual(dominant(pixel(f2, 20, 20)), "B")
        XCTAssertEqual(cache.cachedFrameCount, 3)
        // 全 0 / 空は従来と同じキー(同じ合成結果を再利用)
        XCTAssertTrue(try XCTUnwrap(cache.frame(paths: [base, gif], height: 40, frames: [0, 0])) === f0)
        XCTAssertTrue(try XCTUnwrap(cache.frame(paths: [base, gif], height: 40, frames: [])) === f0)
        XCTAssertEqual(cache.cachedFrameCount, 3)

        // 描画: リグの口パーツがアニメーション(口は常に closed 側の 1 枚)
        var rig = CharacterRig(slots: [RigSlot(name: "体", parts: [base], active: 0), RigSlot(name: "飾り", parts: [gif], active: 0)])
        rig.mouthClosed = nil
        var t = Tachie(name: "リグ"); t.id = "t1"; t.rig = rig
        let p = project(t)
        let assets = RenderAssets()
        XCTAssertEqual(try centerColor(p, t: 0.0, assets: assets), "R")
        XCTAssertEqual(try centerColor(p, t: 0.15, assets: assets), "G")
        XCTAssertEqual(try centerColor(p, t: 0.45, assets: assets), "B")
    }
}
