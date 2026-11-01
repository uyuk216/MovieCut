import XCTest
import CoreGraphics
@testable import MovieCutCore

/// プロキシはプレビューの再生・表示だけが読む。書き出し(`beginExportMode()` = プレビューではない)は元の素材を読む。
final class ProxyRenderTests: XCTestCase {
    private var dir: URL!
    private var source: URL!
    private var proxy: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("proxy-render-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        source = dir.appendingPathComponent("red-source.mp4")
        // 元の素材は赤、プロキシ(偽物)は青。どちらを読んだかで色が変わる。
        try TestVideo.write(to: source, size: (320, 240), frames: 12, rgb: (255, 0, 0))
        proxy = try XCTUnwrap(ProxyStore.proxyURL(for: source, directory: dir))
        try TestVideo.write(to: proxy, size: (320, 240), frames: 12, rgb: (0, 0, 255))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func assets(proxiesOn: Bool) -> RenderAssets {
        let a = RenderAssets()
        let dirPath = dir!
        a.setPreviewProxies(proxiesOn) { ProxyStore.existingProxy(for: URL(fileURLWithPath: $0), directory: dirPath)?.path }
        return a
    }

    private func centerRGB(_ img: CGImage) -> (Int, Int, Int) {
        var d = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let c = CGContext(data: &d, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        let i = ((img.height / 2) * img.width + img.width / 2) * 4
        return (Int(d[i]), Int(d[i + 1]), Int(d[i + 2]))
    }

    private func isRed(_ c: (Int, Int, Int)) -> Bool { c.0 > 200 && c.1 < 60 && c.2 < 60 }
    private func isBlue(_ c: (Int, Int, Int)) -> Bool { c.2 > 200 && c.0 < 60 && c.1 < 60 }

    func testPreviewReadsProxyWhenOnAndSourceWhenOff() throws {
        let on = assets(proxiesOn: true)
        XCTAssertEqual(on.sourcePath(for: source.path), proxy.path)
        let previewOn = try XCTUnwrap(on.videoFrame(path: source.path, time: 0.3))
        XCTAssertTrue(isBlue(centerRGB(previewOn)), "プレビューはプロキシを読む")

        let off = assets(proxiesOn: false)
        XCTAssertEqual(off.sourcePath(for: source.path), source.path)
        let previewOff = try XCTUnwrap(off.videoFrame(path: source.path, time: 0.3))
        XCTAssertTrue(isRed(centerRGB(previewOff)), "設定がオフなら元の素材")
    }

    func testExportNeverReadsProxyEvenWhenOn() throws {
        let a = assets(proxiesOn: true)
        a.beginExportMode()                      // 書き出し(preview ではない)
        XCTAssertEqual(a.sourcePath(for: source.path), source.path, "書き出しはプロキシを選ばない")
        let exported = try XCTUnwrap(a.videoFrame(path: source.path, time: 0.3))
        XCTAssertTrue(isRed(centerRGB(exported)), "書き出しの順次読みも元の素材")
        a.endExportMode()
    }

    func testPlaybackSessionUsesProxyAndEndingItReturnsToSource() throws {
        let a = assets(proxiesOn: true)
        a.beginExportMode(preview: true)         // 再生中の順次読み
        XCTAssertEqual(a.sourcePath(for: source.path), proxy.path)
        XCTAssertTrue(isBlue(centerRGB(try XCTUnwrap(a.videoFrame(path: source.path, time: 0.3)))))
        a.endExportMode()
        XCTAssertEqual(a.sourcePath(for: source.path), proxy.path, "再生を終えたら、プレビューはまたプロキシ")
    }

    func testVideoSizeComesFromSourceNotProxy() throws {
        let a = assets(proxiesOn: true)
        _ = try XCTUnwrap(a.videoFrame(path: source.path, time: 0.1))
        XCTAssertEqual(a.knownVideoSize(path: source.path), CGSize(width: 320, height: 240))
    }

    func testMissingProxyFallsBackToSource() throws {
        let other = dir.appendingPathComponent("no-proxy.mp4")
        try TestVideo.write(to: other, size: (320, 240), frames: 4, rgb: (255, 0, 0))
        let a = assets(proxiesOn: true)
        XCTAssertEqual(a.sourcePath(for: other.path), other.path)
    }

    func testRefreshAfterMakingProxyPicksItUp() throws {
        let fresh = dir.appendingPathComponent("later.mp4")
        try TestVideo.write(to: fresh, size: (320, 240), frames: 4, rgb: (255, 0, 0))
        let a = assets(proxiesOn: true)
        XCTAssertEqual(a.sourcePath(for: fresh.path), fresh.path)
        // あとからプロキシができたら、設定を付け直した時点で読まれる(キャッシュを捨てる)
        try TestVideo.write(to: try XCTUnwrap(ProxyStore.proxyURL(for: fresh, directory: dir)), size: (320, 240), frames: 4, rgb: (0, 0, 255))
        a.setPreviewProxies(true) { ProxyStore.existingProxy(for: URL(fileURLWithPath: $0), directory: self.dir)?.path }
        XCTAssertNotEqual(a.sourcePath(for: fresh.path), fresh.path)
    }
}
