import XCTest
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import MovieCutCore

final class ExporterTests: XCTestCase {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("exporter-tests-\(UUID().uuidString)")
    override func setUpWithError() throws { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    /// 2 秒のプロジェクト: 文字 + トーンのボイス(1.85 秒 + 0.15)。
    func twoSecondProject(w: Int = 640, h: Int = 360, fps: Int = 30, codec: String = "h264", withAudio: Bool = true) throws -> Project {
        var p = Project.new()
        p.width = w; p.height = h; p.fps = fps; p.codec = codec
        var text = Clip(); text.type = .text; text.text = "テスト"; text.start = 0; text.duration = 2
        text.x = 0.5; text.y = 0.3; text.fontSize = 60
        p.tracks[4].clips.append(text)
        if withAudio {
            let wav = tmp.appendingPathComponent("tone-\(UUID().uuidString).wav")
            try ToneVoiceProvider.writeTone(to: wav, duration: 1.85, frequency: 330)
            var v = Clip(); v.type = .voice; v.start = 0; v.duration = 2; v.src = wav.path; v.text = "ぴー"
            v.charId = p.characters[0].id; v.volume = 1; v.subtitle = true; v.fontSize = 40
            p.tracks[0].clips.append(v)
        }
        return p
    }

    struct Info { var size: CGSize; var fps: Float; var videoDur: Double; var audioDur: Double?; var total: Double; var codec: FourCharCode }

    func inspect(_ url: URL) async throws -> Info {
        let asset = AVURLAsset(url: url)
        let v = try await asset.loadTracks(withMediaType: .video)
        let a = try await asset.loadTracks(withMediaType: .audio)
        let vt = try XCTUnwrap(v.first, "映像トラックがない")
        let size = try await vt.load(.naturalSize)
        let fps = try await vt.load(.nominalFrameRate)
        let vr = try await vt.load(.timeRange)
        var ad: Double?
        if let at = a.first { ad = try await at.load(.timeRange).duration.seconds }
        let total = try await asset.load(.duration).seconds
        let fd = try await vt.load(.formatDescriptions)
        let codec = CMFormatDescriptionGetMediaSubType(fd[0])
        return Info(size: size, fps: fps, videoDur: vr.duration.seconds, audioDur: ad, total: total, codec: codec)
    }

    func testExportH264WithAudio() async throws {
        let p = try twoSecondProject()
        let out = tmp.appendingPathComponent("a.mp4")
        var last = 0.0
        var calls = 0
        try await Exporter(project: p, assets: RenderAssets()).export(to: out) { v in XCTAssertGreaterThanOrEqual(v, last); last = v; calls += 1 }
        XCTAssertEqual(last, 1.0)
        XCTAssertGreaterThan(calls, 5)
        let i = try await inspect(out)
        XCTAssertEqual(i.size, CGSize(width: 640, height: 360))
        XCTAssertEqual(i.fps, 30, accuracy: 0.5)
        XCTAssertEqual(i.codec, kCMVideoCodecType_H264)
        let ad = try XCTUnwrap(i.audioDur, "音声トラックがない")
        XCTAssertEqual(i.videoDur, 2.0, accuracy: 0.05)
        XCTAssertEqual(ad, 2.0, accuracy: 0.05)
        XCTAssertEqual(abs(i.videoDur - ad), 0, accuracy: 0.05)
        XCTAssertEqual(i.total, 2.0, accuracy: 0.05)
    }

    func testExportHEVCUsesHvc1() async throws {
        let p = try twoSecondProject(codec: "hevc")
        let out = tmp.appendingPathComponent("h.mp4")
        try await Exporter(project: p, assets: RenderAssets()).export(to: out, progress: nil)
        let i = try await inspect(out)
        XCTAssertEqual(i.codec, kCMVideoCodecType_HEVC)  // 'hvc1'(QuickTime が読む)
        XCTAssertEqual(i.size, CGSize(width: 640, height: 360))
        XCTAssertNotNil(i.audioDur)
        XCTAssertEqual(i.videoDur, 2.0, accuracy: 0.05)
    }

    func testOddSizeIsRoundedDownToEven() async throws {
        let p = try twoSecondProject(w: 1081, h: 607, fps: 24)
        let out = tmp.appendingPathComponent("odd.mp4")
        let ex = Exporter(project: p, assets: RenderAssets())
        XCTAssertEqual(ex.outputSize.width, 1080); XCTAssertEqual(ex.outputSize.height, 606)
        try await ex.export(to: out, progress: nil)
        let i = try await inspect(out)
        XCTAssertEqual(i.size, CGSize(width: 1080, height: 606))
        XCTAssertEqual(i.fps, 24, accuracy: 0.5)
    }

    func testNoAudioProjectStillExports() async throws {
        let p = try twoSecondProject(withAudio: false)
        let out = tmp.appendingPathComponent("silent.mp4")
        try await Exporter(project: p, assets: RenderAssets()).export(to: out, progress: nil)
        let i = try await inspect(out)
        XCTAssertNil(i.audioDur)
        XCTAssertEqual(i.videoDur, 2.0, accuracy: 0.05)
    }

    func testEmptyProjectThrows() async {
        let out = tmp.appendingPathComponent("e.mp4")
        do { try await Exporter(project: Project.new(), assets: RenderAssets()).export(to: out, progress: nil); XCTFail("例外になるはず") }
        catch { XCTAssertTrue(error is ExportError); XCTAssertFalse(error.localizedDescription.isEmpty) }
    }

    func testExistingOutputIsReplaced() async throws {
        let out = tmp.appendingPathComponent("x.mp4")
        try Data("old".utf8).write(to: out)
        try await Exporter(project: try twoSecondProject(withAudio: false), assets: RenderAssets()).export(to: out, progress: nil)
        let i = try await inspect(out)
        XCTAssertEqual(i.videoDur, 2.0, accuracy: 0.05)
    }

    func testCancelDeletesPartialFile() async throws {
        var p = try twoSecondProject(w: 1920, h: 1080, fps: 60)
        p.tracks[4].clips[0].duration = 30  // 1800 コマ: 十分に長い
        let out = tmp.appendingPathComponent("cancel.mp4")
        let ex = Exporter(project: p, assets: RenderAssets())
        let started = expectation(description: "progress")
        started.assertForOverFulfill = false
        let task = Task { try await ex.export(to: out) { _ in started.fulfill() } }
        await fulfillment(of: [started], timeout: 30)
        task.cancel()
        do { try await task.value; XCTFail("キャンセルされるはず") }
        catch is CancellationError {}
        catch { XCTFail("CancellationError のはずが \(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path), "途中のファイルが残っている")
    }

    // MARK: 動画クリップ

    func solidPNG(_ name: String, r: CGFloat, g: CGFloat, b: CGFloat, w: Int, h: Int) throws -> String {
        let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let url = tmp.appendingPathComponent(name)
        let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(d, c.makeImage()!, nil); CGImageDestinationFinalize(d)
        return url.path
    }

    func frame(_ url: URL, at t: Double) throws -> (r: Int, g: Int, b: Int) {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
        let img = try gen.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil)
        var d = [UInt8](repeating: 0, count: 4)
        let c = CGContext(data: &d, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.interpolationQuality = .medium
        c.draw(img, in: CGRect(x: -img.width / 2, y: -img.height / 2, width: img.width, height: img.height))  // 中央 1 画素
        return (Int(d[0]), Int(d[1]), Int(d[2]))
    }

    func assertColor(_ c: (r: Int, g: Int, b: Int), _ expect: (Int, Int, Int), _ msg: String, file: StaticString = #filePath, line: UInt = #line) {
        let ok = abs(c.r - expect.0) < 40 && abs(c.g - expect.1) < 40 && abs(c.b - expect.2) < 40
        XCTAssertTrue(ok, "\(msg): got \(c) expected \(expect)", file: file, line: line)
    }

    func testVideoClipFramesFollowOffset() async throws {
        let red = try solidPNG("red.png", r: 1, g: 0, b: 0, w: 160, h: 90)
        let blue = try solidPNG("blue.png", r: 0, g: 0, b: 1, w: 160, h: 90)
        // 1) 赤 1 秒 → 青 1 秒の動画を作る
        var p1 = Project.new(); p1.width = 160; p1.height = 90; p1.fps = 30
        var a = Clip(); a.type = .image; a.src = red; a.start = 0; a.duration = 1
        var b = Clip(); b.type = .image; b.src = blue; b.start = 1; b.duration = 1
        p1.tracks[0].clips = [a, b]
        let src = tmp.appendingPathComponent("halves.mp4")
        try await Exporter(project: p1, assets: RenderAssets()).export(to: src, progress: nil)
        assertColor(try frame(src, at: 0.3), (255, 0, 0), "元動画 0.3")
        assertColor(try frame(src, at: 1.7), (0, 0, 255), "元動画 1.7")

        // 2) それを offset 0.5 で動画クリップにする: 出力 t は元動画の t+0.5
        var p2 = Project.new(); p2.width = 160; p2.height = 90; p2.fps = 30
        var v = Clip(); v.type = .video; v.src = src.path; v.start = 0; v.duration = 1.5; v.offset = 0.5; v.srcDuration = 2
        p2.tracks[0].clips = [v]
        let out = tmp.appendingPathComponent("second.mp4")
        let assets = RenderAssets()
        try await Exporter(project: p2, assets: assets).export(to: out, progress: nil)
        assertColor(try frame(out, at: 0.2), (255, 0, 0), "t=0.2 → 元 0.7(赤)")
        assertColor(try frame(out, at: 0.4), (255, 0, 0), "t=0.4 → 元 0.9(赤)")
        assertColor(try frame(out, at: 0.6), (0, 0, 255), "t=0.6 → 元 1.1(青)")
        assertColor(try frame(out, at: 1.2), (0, 0, 255), "t=1.2 → 元 1.7(青)")
        let i = try await inspect(out)
        XCTAssertEqual(i.videoDur, 1.5, accuracy: 0.05)
    }

    func testSequentialReaderMatchesGeneratorAndHandlesSeeks() async throws {
        let red = try solidPNG("red.png", r: 1, g: 0, b: 0, w: 64, h: 36)
        let blue = try solidPNG("blue.png", r: 0, g: 0, b: 1, w: 64, h: 36)
        var p1 = Project.new(); p1.width = 64; p1.height = 36; p1.fps = 30
        var a = Clip(); a.type = .image; a.src = red; a.start = 0; a.duration = 1
        var b = Clip(); b.type = .image; b.src = blue; b.start = 1; b.duration = 1
        p1.tracks[0].clips = [a, b]
        let src = tmp.appendingPathComponent("halves.mp4")
        try await Exporter(project: p1, assets: RenderAssets()).export(to: src, progress: nil)
        func color(_ img: CGImage?) -> (Int, Int, Int)? {
            guard let img = img else { return nil }
            var d = [UInt8](repeating: 0, count: 4)
            let c = CGContext(data: &d, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.draw(img, in: CGRect(x: -img.width / 2, y: -img.height / 2, width: img.width, height: img.height))
            return (Int(d[0]), Int(d[1]), Int(d[2]))
        }
        let assets = RenderAssets()
        assets.beginExportMode()
        defer { assets.endExportMode() }
        // 順方向 → 戻る → 大きく先へ → 末尾の先(最後のフレーム)
        let steps: [(Double, Bool)] = [(0.0, true), (0.5, true), (0.9, true), (1.2, false), (0.2, true), (1.9, false), (5.0, false)]
        for (t, isRed) in steps {
            let c = try XCTUnwrap(color(assets.videoFrame(path: src.path, time: t)), "t=\(t) でフレームなし")
            XCTAssertTrue(isRed ? c.0 > 200 && c.2 < 60 : c.2 > 200 && c.0 < 60, "t=\(t): \(c)")
        }
        XCTAssertNil(assets.videoFrame(path: tmp.appendingPathComponent("none.mp4").path, time: 0))
    }

    // MARK: 台本・トーン

    func testScriptTimelineLikeElectron() async throws {
        let p = try await ScriptTimeline.smokeProject(size: (3840, 2160), codec: "hevc", blur: true, voice: ToneVoiceProvider(), directory: tmp)
        XCTAssertEqual(p.codec, "hevc")
        let v = p.tracks[0].clips
        XCTAssertEqual(v.count, 2)
        XCTAssertEqual(v[0].duration, 1.85, accuracy: 1e-9)
        XCTAssertEqual(v[1].start, 1.85 + 0.1, accuracy: 1e-9)
        XCTAssertEqual(v[1].duration, 1.75, accuracy: 1e-9)
        XCTAssertEqual(v[0].charId, p.characters[0].id)
        XCTAssertEqual(v[1].charId, p.characters[2].id)
        XCTAssertEqual(v[0].fontSize, 128)            // 64 × 2(4K)
        XCTAssertEqual(p.tracks[4].clips.first { $0.type == .text }?.fontSize, 240)
        XCTAssertEqual(p.tracks[4].clips.first { $0.type == .blur }?.strength, 60)
        XCTAssertEqual(p.endTime, 1.85 + 0.1 + 1.75, accuracy: 1e-9)
        XCTAssertEqual(Exporter(project: p, assets: RenderAssets()).totalFrames, 222)  // 3.7 × 60(浮動小数で 223 にならない)
    }

    func testCachedTextMatchesDirectDrawing() throws {
        var p = Project.new(); p.width = 400; p.height = 200
        let r = Renderer(project: p, assets: RenderAssets())
        func draw(_ cache: Bool) -> [UInt8] {
            let ctx = Renderer.makeContext(width: 400, height: 200)!
            ctx.translateBy(x: 0, y: 200); ctx.scaleBy(x: 1, y: -1)
            ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.2, blue: 0.2, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
            r.drawText("ゆっくり\nテスト", x: 200.37, y: 100.61, size: 48, color: "#ffee00", font: defaultFonts[0], outline: "#e8384f", ctx: ctx, cacheable: cache)
            let img = ctx.makeImage()!
            var d = [UInt8](repeating: 0, count: 400 * 200 * 4)
            let c = CGContext(data: &d, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 1600, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            c.draw(img, in: CGRect(x: 0, y: 0, width: 400, height: 200))
            return d
        }
        let direct = draw(false), cached1 = draw(true), cached2 = draw(true)
        XCTAssertEqual(cached1, cached2)
        var maxDiff = 0, bigDiff = 0
        for i in 0..<direct.count { let d = abs(Int(direct[i]) - Int(cached1[i])); maxDiff = max(maxDiff, d); if d > 4 { bigDiff += 1 } }
        XCTAssertLessThanOrEqual(maxDiff, 6, "キャッシュ描画が直接描画とずれている(最大差 \(maxDiff))")
        XCTAssertEqual(bigDiff, 0)
    }
}
