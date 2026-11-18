import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import MovieCutCore

final class RenderAssetsBudgetTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mc-budget-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func writePNG(_ name: String, size: Int = 64) throws -> String {
        let cs = CGColorSpaceCreateDeviceRGB()
        let c = try XCTUnwrap(CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        c.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        c.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let url = dir.appendingPathComponent(name)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(c.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url.path
    }

    func testImagesEvictedLRUAndReloadable() throws {
        let a = try writePNG("a.png"), b = try writePNG("b.png"), c = try writePNG("c.png")
        let probe = try XCTUnwrap(RenderAssets().image(at: a))
        let cost = Int64(probe.bytesPerRow * probe.height)
        // 2 枚ぶん + 少しだけ入る上限
        let mgr = CacheBudgetManager(limitBytes: cost * 2 + cost / 2)
        let assets = RenderAssets()
        assets.setBudgetManager(mgr)

        XCTAssertNotNil(assets.image(at: a))
        XCTAssertNotNil(assets.image(at: b))
        XCTAssertEqual(mgr.keysInLRUOrder, ["image:" + a, "image:" + b])
        XCTAssertNotNil(assets.image(at: c))
        // 最も古い a が落ちる
        XCTAssertFalse(mgr.contains("image:" + a))
        XCTAssertTrue(mgr.contains("image:" + b))
        XCTAssertTrue(mgr.contains("image:" + c))
        XCTAssertLessThanOrEqual(mgr.totalBytes, mgr.limitBytes ?? 0)

        // 落ちた画像も再取得できる(再登録で b が落ちる)
        XCTAssertNotNil(assets.image(at: a))
        XCTAssertTrue(mgr.contains("image:" + a))
        XCTAssertFalse(mgr.contains("image:" + b))
    }

    func testImageHitTouchesToMostRecent() throws {
        let a = try writePNG("a.png"), b = try writePNG("b.png"), c = try writePNG("c.png")
        let probe = try XCTUnwrap(RenderAssets().image(at: a))
        let cost = Int64(probe.bytesPerRow * probe.height)
        let mgr = CacheBudgetManager(limitBytes: cost * 2 + cost / 2)
        let assets = RenderAssets()
        assets.setBudgetManager(mgr)
        _ = assets.image(at: a); _ = assets.image(at: b)
        _ = assets.image(at: a)   // a を使い直す → b が最古
        _ = assets.image(at: c)
        XCTAssertTrue(mgr.contains("image:" + a))
        XCTAssertFalse(mgr.contains("image:" + b))
    }

    func testPurgeAllThenImagesReload() throws {
        let a = try writePNG("a.png")
        let mgr = CacheBudgetManager(limitBytes: nil)
        let assets = RenderAssets()
        assets.setBudgetManager(mgr)
        XCTAssertNotNil(assets.image(at: a))
        XCTAssertEqual(mgr.count, 1)
        mgr.purgeAll()
        XCTAssertEqual(mgr.count, 0)
        XCTAssertNotNil(assets.image(at: a))
        XCTAssertEqual(mgr.count, 1)
    }

    func testWithoutManagerNothingRegistered() throws {
        let a = try writePNG("a.png")
        let assets = RenderAssets()
        XCTAssertNotNil(assets.image(at: a))
        let mgr = CacheBudgetManager(limitBytes: 0)
        assets.setBudgetManager(mgr)
        XCTAssertNotNil(assets.image(at: a))   // 既存キャッシュのヒット: 登録されない
        XCTAssertEqual(mgr.count, 0)
    }

    func testScaledPixelSizeAndClamp() {
        XCTAssertEqual(RenderAssets.scaledPixelSize(CGSize(width: 1920, height: 1080), scale: 0.5), CGSize(width: 960, height: 540))
        XCTAssertEqual(RenderAssets.scaledPixelSize(CGSize(width: 1920, height: 1080), scale: 0.25), CGSize(width: 480, height: 270))
        XCTAssertEqual(RenderAssets.scaledPixelSize(CGSize(width: 3, height: 2), scale: 0.1), CGSize(width: 1, height: 1))
        XCTAssertEqual(RenderAssets.clampedVideoScale(2), 1)
        XCTAssertEqual(RenderAssets.clampedVideoScale(0), 1)
        XCTAssertEqual(RenderAssets.clampedVideoScale(-1), 1)
        XCTAssertEqual(RenderAssets.clampedVideoScale(.nan), 1)
        XCTAssertEqual(RenderAssets.clampedVideoScale(0.25), 0.25)
    }

    func testSequentialDownscaledSize() throws {
        let path = try writePNG("big.png", size: 100)
        let img = try XCTUnwrap(RenderAssets().image(at: path))
        let half = SequentialVideoFrames.downscaled(img, scale: 0.5)
        XCTAssertEqual(half.width, 50); XCTAssertEqual(half.height, 50)
        let tiny = SequentialVideoFrames.downscaled(img, scale: 0.001)
        XCTAssertEqual(tiny.width, 1); XCTAssertEqual(tiny.height, 1)
    }
}
