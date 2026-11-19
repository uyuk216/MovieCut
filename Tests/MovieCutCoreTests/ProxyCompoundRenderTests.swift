import XCTest
import CoreGraphics
@testable import MovieCutCore

/// 複合クリップ・シーンの中の映像も、プレビューはプロキシ、書き出しは原本を読む(子の Renderer は同じ assets を共有する)。
final class ProxyCompoundRenderTests: XCTestCase {
    private var dir: URL!
    private var source: URL!
    private var proxy: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("proxy-compound-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        source = dir.appendingPathComponent("red-source.mp4")
        try TestVideo.write(to: source, size: (320, 240), frames: 12, rgb: (255, 0, 0))
        proxy = try XCTUnwrap(ProxyStore.proxyURL(for: source, directory: dir))
        try TestVideo.write(to: proxy, size: (320, 240), frames: 12, rgb: (0, 0, 255))
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

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

    private func videoClip() -> Clip {
        var v = Clip(); v.id = "v"; v.type = .video; v.src = source.path; v.start = 0; v.duration = 1; v.srcDuration = 1.2
        return v
    }
    private func baseProject() -> Project {
        var p = Project(); p.width = 320; p.height = 240
        p.tracks = [Track(name: "main")]
        return p
    }
    private func compoundProject() -> Project {
        var c = Clip(); c.id = "comp"; c.type = .compound; c.start = 0; c.duration = 1
        var t = Track(name: "inner"); t.clips = [videoClip()]
        c.tracks = [t]
        var p = baseProject(); p.tracks[0].clips = [c]
        return p
    }
    private func sceneProject() -> Project {
        var sc = SceneDefinition(); sc.id = "S1"; sc.name = "S"
        var t = Track(name: "t"); t.clips = [videoClip()]
        sc.tracks = [t]
        var s = Clip(); s.id = "sc"; s.type = .scene; s.sceneId = "S1"; s.start = 0; s.duration = 1
        var p = baseProject(); p.tracks[0].clips = [s]; p.scenes = [sc]
        return p
    }

    private func check(_ p: Project) throws {
        let on = assets(proxiesOn: true)
        let preview = try XCTUnwrap(Renderer(project: p, assets: on).renderImage(t: 0.3))
        XCTAssertTrue(isBlue(centerRGB(preview)), "プレビューは入れ子の中でもプロキシ: \(centerRGB(preview))")

        let ex = assets(proxiesOn: true)
        ex.beginExportMode()
        let exported = try XCTUnwrap(Renderer(project: p, assets: ex).renderImage(t: 0.3))
        XCTAssertTrue(isRed(centerRGB(exported)), "書き出しは入れ子の中でも原本: \(centerRGB(exported))")
        ex.endExportMode()

        let off = assets(proxiesOn: false)
        let plain = try XCTUnwrap(Renderer(project: p, assets: off).renderImage(t: 0.3))
        XCTAssertTrue(isRed(centerRGB(plain)), "設定オフは原本")
    }

    func testCompoundClipPreviewUsesProxyExportUsesSource() throws { try check(compoundProject()) }
    func testSceneClipPreviewUsesProxyExportUsesSource() throws { try check(sceneProject()) }
}
