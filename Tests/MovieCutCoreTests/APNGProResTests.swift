import XCTest
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import MovieCutCore

/// APNG(ImageIO)と ProRes 422 / 4444(AVAssetWriter)の書き出し。書かれたファイルを開き直して確かめる。
final class APNGProResTests: XCTestCase {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("apng-prores-\(UUID().uuidString)")
    override func setUpWithError() throws { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    /// 文字だけの 1 秒のプロジェクト。`transparent` なら背景は透明。
    private func project(width: Int = 320, height: Int = 180, duration: Double = 1, fps: Double = 30, transparent: Bool = false, codec: String = "h264") -> Project {
        var p = Project.new()
        p.width = width; p.height = height; p.fps = fps; p.codec = codec
        p.bg = transparent ? Project.transparentBackground : "#2040c0"
        var t = Clip(); t.type = .text; t.text = "国"; t.start = 0; t.duration = duration; t.fontSize = 90; t.x = 0.5; t.y = 0.5
        t.color = "#ffffff"
        p.tracks[4].clips.append(t)
        return p
    }

    /// 画素(RGBA、非プリマルチ想定ではなく CGContext の premultipliedLast で読む)。
    private func alphaAt(_ img: CGImage, _ x: Int, _ y: Int) -> Int {
        var d = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let c = CGContext(data: &d, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.clear(CGRect(x: 0, y: 0, width: img.width, height: img.height))
        c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return Int(d[(y * img.width + x) * 4 + 3])
    }

    // MARK: APNG

    func testAPNGPlanMatchesFpsAndWidth() {
        let p = project(width: 1920, height: 1080, duration: 2)
        let plan = APNGExporter.plan(project: p, range: nil, options: APNGOptions(fps: 15, maxWidth: 480))
        XCTAssertEqual(plan.width, 480); XCTAssertEqual(plan.height, 270)
        XCTAssertEqual(plan.frames, 30)
        XCTAssertEqual(plan.delay, 1.0 / 15, accuracy: 1e-9)
        XCTAssertEqual(APNGOptions(loopCount: -5).loopCount, 0)
        XCTAssertEqual(APNGOptions(loopCount: 99999).loopCount, 1000)
        XCTAssertNil(APNGOptions.validFPS(0)); XCTAssertNil(APNGOptions.validFPS(.nan)); XCTAssertEqual(APNGOptions.validFPS(60), 60)
    }

    func testAPNGFileHasFramesDelaysAndLoopCount() async throws {
        let p = project(duration: 1)
        let out = tmp.appendingPathComponent("a.png")
        let r = try await APNGExporter.export(project: p, options: APNGOptions(fps: 10, maxWidth: 160, loopCount: 3), to: out)
        XCTAssertEqual(r.frameCount, 10)
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(out as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(src) as String?, "public.png")
        XCTAssertEqual(CGImageSourceGetCount(src), 10, "10 コマの APNG")
        let first = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
        XCTAssertEqual(first[kCGImagePropertyPixelWidth] as? Int, 160)
        XCTAssertEqual(first[kCGImagePropertyPixelHeight] as? Int, 90)
        for i in 0..<10 {
            let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
            let png = props?[kCGImagePropertyPNGDictionary] as? [CFString: Any]
            let delay = (png?[kCGImagePropertyAPNGDelayTime] as? Double) ?? -1
            XCTAssertEqual(delay, 0.1, accuracy: 0.001, "コマ \(i) の時間")
        }
        let file = CGImageSourceCopyProperties(src, nil) as? [CFString: Any]
        let loop = (file?[kCGImagePropertyPNGDictionary] as? [CFString: Any])?[kCGImagePropertyAPNGLoopCount] as? Int
        XCTAssertEqual(loop, 3, "ループ回数")
        XCTAssertEqual(r.loopCount, 3)
        XCTAssertEqual(r.bytes, (try FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int))
        // 一時ファイルは残らない
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tmp.path).filter { $0.hasSuffix(".part") }, [])
    }

    func testAPNGDefaultsToInfiniteLoop() async throws {
        let out = tmp.appendingPathComponent("inf.png")
        try await APNGExporter.export(project: project(duration: 0.5), options: APNGOptions(fps: 10, maxWidth: 160), to: out)
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(out as CFURL, nil))
        let file = CGImageSourceCopyProperties(src, nil) as? [CFString: Any]
        XCTAssertEqual((file?[kCGImagePropertyPNGDictionary] as? [CFString: Any])?[kCGImagePropertyAPNGLoopCount] as? Int, 0)
        XCTAssertEqual(CGImageSourceGetCount(src), 5)
    }

    func testAPNGKeepsTransparencyAndOpaqueBackgroundIsOpaque() async throws {
        let clear = tmp.appendingPathComponent("clear.png"), solid = tmp.appendingPathComponent("solid.png")
        try await APNGExporter.export(project: project(transparent: true), options: APNGOptions(fps: 5, maxWidth: nil), to: clear)
        try await APNGExporter.export(project: project(transparent: false), options: APNGOptions(fps: 5, maxWidth: nil), to: solid)
        let c = try XCTUnwrap(CGImageSourceCreateImageAtIndex(try XCTUnwrap(CGImageSourceCreateWithURL(clear as CFURL, nil)), 0, nil))
        XCTAssertEqual(alphaAt(c, 3, 3), 0, "背景は透明のまま")
        XCTAssertEqual(alphaAt(c, 160, 90), 255, "文字の中心は不透明")
        let s = try XCTUnwrap(CGImageSourceCreateImageAtIndex(try XCTUnwrap(CGImageSourceCreateWithURL(solid as CFURL, nil)), 0, nil))
        XCTAssertEqual(alphaAt(s, 3, 3), 255)
    }

    func testAPNGRangeAndEmptyProject() async throws {
        let p = project(duration: 4)
        let out = tmp.appendingPathComponent("r.png")
        let r = try await APNGExporter.export(project: p, range: ExportRange(start: 1, end: 2), options: APNGOptions(fps: 10, maxWidth: 160), to: out)
        XCTAssertEqual(r.frameCount, 10)
        var empty = Project.new(); empty.width = 320; empty.height = 180
        do { _ = try await APNGExporter.export(project: empty, to: tmp.appendingPathComponent("e.png")); XCTFail("空は書けない") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("e.png").path))
    }

    func testAPNGCancellationLeavesExistingFileUntouched() async throws {
        let out = tmp.appendingPathComponent("keep.png")
        try Data("old".utf8).write(to: out)
        let task = Task { try await APNGExporter.export(project: project(duration: 30), options: APNGOptions(fps: 30, maxWidth: nil), to: out) }
        task.cancel()
        do { _ = try await task.value; XCTFail("キャンセルされるはず") } catch is CancellationError {}
        XCTAssertEqual(try Data(contentsOf: out), Data("old".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tmp.path).filter { $0.contains(".part") }, [])
    }

    // MARK: ProRes

    func testOutputPlanKnowsProRes() {
        XCTAssertEqual(OutputPlan.make(width: 3840, height: 2160, codec: "prores422").codec, "prores422")
        let p = OutputPlan.make(width: 8000, height: 4000, codec: "prores4444")
        XCTAssertEqual(p.codec, "prores4444", "ProRes は H.264 の上限で HEVC に切り替わらない")
        XCTAssertFalse(p.usesFallbackCodec)
        XCTAssertTrue(p.isProRes)
        XCTAssertEqual(p.fileExtension, "mov")
        XCTAssertEqual(OutputPlan.make(width: 1920, height: 1080, codec: "h264").fileExtension, "mp4")
        XCTAssertEqual(OutputPlan.make(width: 1920, height: 1080, codec: "unknown").codec, "h264")
        XCTAssertEqual(OutputPlan.codecLabel("prores4444"), "ProRes 4444")
        XCTAssertNotNil(OutputPlan.make(width: 20000, height: 20000, codec: "prores422").error)
    }

    private struct ProInfo { var codec: FourCharCode; var frames: Int; var duration: Double; var depth: Int?; var firstAlpha: Int?; var audioFormat: AudioFormatID? }

    /// 書かれた .mov を開き直して、コーデック・コマ数・(アルファ付きなら)左上の画素のアルファを読む。
    private func inspect(_ url: URL, wantAlpha: Bool = false) async throws -> ProInfo {
        let asset = AVURLAsset(url: url)
        let vtracks = try await asset.loadTracks(withMediaType: .video)
        let vt = try XCTUnwrap(vtracks.first)
        let fd = try await vt.load(.formatDescriptions)
        let codec = CMFormatDescriptionGetMediaSubType(fd[0])
        let depth = (CMFormatDescriptionGetExtension(fd[0], extensionKey: kCMFormatDescriptionExtension_Depth) as? NSNumber)?.intValue
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: vt, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(out)
        XCTAssertTrue(reader.startReading())
        var n = 0
        var alpha: Int?
        while let sb = out.copyNextSampleBuffer() {
            if n == 0, wantAlpha, let pb = CMSampleBufferGetImageBuffer(sb) {
                CVPixelBufferLockBaseAddress(pb, .readOnly)
                let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
                alpha = Int(base[3])  // BGRA の左上(0, 0)の A
                CVPixelBufferUnlockBaseAddress(pb, .readOnly)
            }
            n += 1
        }
        let dur = try await asset.load(.duration).seconds
        var af: AudioFormatID?
        if let at = try await asset.loadTracks(withMediaType: .audio).first {
            let afd = try await at.load(.formatDescriptions)
            af = CMFormatDescriptionGetMediaSubType(afd[0])
        }
        return ProInfo(codec: codec, frames: n, duration: dur, depth: depth, firstAlpha: alpha, audioFormat: af)
    }

    func testExportProRes422OneSecond() async throws {
        let p = project(width: 320, height: 180, duration: 1, fps: 30, codec: "prores422")
        let out = tmp.appendingPathComponent("p422.mov")
        try await Exporter(project: p, assets: RenderAssets()).export(to: out)
        let info = try await inspect(out)
        XCTAssertEqual(info.codec, kCMVideoCodecType_AppleProRes422, "ProRes 422 で書かれている")
        XCTAssertEqual(info.frames, 30)
        XCTAssertEqual(info.duration, 1, accuracy: 0.05)
        // 拡張子ではなく中身が QuickTime
        let head = try Data(contentsOf: out).prefix(12)
        XCTAssertEqual(String(decoding: head.dropFirst(4), as: UTF8.self).prefix(4), "ftyp")
        XCTAssertTrue(String(decoding: try Data(contentsOf: out).prefix(16), as: UTF8.self).contains("qt"))
    }

    func testExportProRes4444KeepsAlphaWhenBackgroundIsTransparent() async throws {
        let p = project(width: 320, height: 180, duration: 1, fps: 30, transparent: true, codec: "prores4444")
        let out = tmp.appendingPathComponent("p4444.mov")
        try await Exporter(project: p, assets: RenderAssets()).export(to: out)
        let info = try await inspect(out, wantAlpha: true)
        XCTAssertEqual(info.codec, kCMVideoCodecType_AppleProRes4444)
        XCTAssertEqual(info.frames, 30)
        XCTAssertEqual(info.depth, 32, "アルファ付き(深さ 32)")
        XCTAssertEqual(info.firstAlpha ?? -1, 0, "背景は透明のまま")
    }

    func testExportProRes4444WithOpaqueBackgroundIsOpaque() async throws {
        let p = project(width: 320, height: 180, duration: 1, fps: 30, transparent: false, codec: "prores4444")
        let out = tmp.appendingPathComponent("p4444o.mov")
        try await Exporter(project: p, assets: RenderAssets()).export(to: out)
        let info = try await inspect(out, wantAlpha: true)
        XCTAssertEqual(info.codec, kCMVideoCodecType_AppleProRes4444)
        XCTAssertGreaterThanOrEqual(info.firstAlpha ?? -1, 250, "背景は不透明(ProRes の量子化で 1 ほど動く)")
    }

    func testProResWithAudioUsesPCMInMov() async throws {
        var p = project(width: 320, height: 180, duration: 1, fps: 30, codec: "prores422")
        let wav = tmp.appendingPathComponent("tone.wav")
        try ToneVoiceProvider.writeTone(to: wav, duration: 0.9, frequency: 330)
        var v = Clip(); v.type = .voice; v.start = 0; v.duration = 1; v.src = wav.path; v.text = "ぴー"; v.charId = p.characters[0].id; v.volume = 1; v.subtitle = false
        p.tracks[0].clips.append(v)
        let out = tmp.appendingPathComponent("pa.mov")
        try await Exporter(project: p, assets: RenderAssets()).export(to: out)
        let info = try await inspect(out)
        XCTAssertEqual(info.audioFormat, kAudioFormatLinearPCM)
        XCTAssertEqual(info.frames, 30)
    }

    func testTransparentBackgroundIsBlackInH264AndStillPNGKeepsAlpha() async throws {
        let p = project(width: 320, height: 180, duration: 1, fps: 30, transparent: true, codec: "h264")
        let out = tmp.appendingPathComponent("t.mp4")
        try await Exporter(project: p, assets: RenderAssets()).export(to: out)
        let info = try await inspect(out)
        XCTAssertEqual(info.codec, kCMVideoCodecType_H264)
        let img = try XCTUnwrap(Renderer(project: p, assets: RenderAssets()).renderImage(t: 0.1))
        XCTAssertEqual(alphaAt(img, 2, 2), 0)
        XCTAssertTrue(p.hasTransparentBackground)
        var q = p; q.bg = "#000000"
        XCTAssertFalse(q.hasTransparentBackground)
    }

    func testH264ExportUnchangedByOptionalProResCode() async throws {
        let p = project(width: 320, height: 180, duration: 1, fps: 30, codec: "hevc")
        let out = tmp.appendingPathComponent("h.mp4")
        try await Exporter(project: p, assets: RenderAssets()).export(to: out)
        let info = try await inspect(out)
        XCTAssertEqual(info.codec, kCMVideoCodecType_HEVC)
        XCTAssertEqual(info.frames, 30)
    }
}
