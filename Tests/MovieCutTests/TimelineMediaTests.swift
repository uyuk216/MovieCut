import XCTest
import AppKit
import SwiftUI
import AVFoundation
import MovieCutCore
@testable import MovieCut

/// A6: サムネイルと波形(裏で作って、できたら描く)。合成の画像・トーンの WAV・数コマの MP4 で、描画を画面の外に出して PNG で確かめる。
@MainActor
final class TimelineMediaTests: XCTestCase {
    static let outDir = ProcessInfo.processInfo.environment["MC_SNAPSHOT_OUT_DIR"]
        ?? "/private/tmp/claude-501/-Users-USER------------/07529bfa-5715-4444-bf9c-c37229b6ab4d/scratchpad/a6-timeline"
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("a6-media-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        TimelineMediaCache.shared.removeAll()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: 合成素材

    /// 横に色が変わるグラデーションの PNG(中身が見分けられるよう、中央に白い四角)。
    func makePNG(_ name: String = "pic.png") throws -> String {
        let w = 320, h = 180
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for y in 0..<h { for x in 0..<w {
            let inBox = abs(x - w / 2) < 30 && abs(y - h / 2) < 30
            let c = inBox ? NSColor(calibratedRed: 1, green: 1, blue: 1, alpha: 1) : NSColor(calibratedRed: CGFloat(x) / CGFloat(w), green: 0.45, blue: 1 - CGFloat(x) / CGFloat(w), alpha: 1)
            rep.setColor(c, atX: x, y: y)
        } }
        let url = dir.appendingPathComponent(name)
        try rep.representation(using: .png, properties: [:])!.write(to: url)
        return url.path
    }

    /// 3 秒のトーン(0〜1 秒は大きく、1〜2 秒は小さく、2〜3 秒は大きく)の WAV。
    func makeTone(_ name: String = "tone.wav") throws -> String {
        let url = dir.appendingPathComponent(name)
        try Self.writeWav(url: url) { t in
            let amp = (t >= 1 && t < 2) ? 0.2 : 0.8
            return amp * sin(2 * .pi * 440 * t)
        }
        return url.path
    }

    static func writeWav(url: URL, rate: Int = 44100, seconds: Double = 3, _ f: (Double) -> Double) throws {
        let frames = Int(Double(rate) * seconds)
        var data = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; data.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; data.append(Data(bytes: &x, count: 2)) }
        data.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + frames * 2)); data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        data.append("data".data(using: .ascii)!); u32(UInt32(frames * 2))
        for i in 0..<frames { u16(UInt16(bitPattern: Int16((max(-1, min(1, f(Double(i) / Double(rate)))) * 32767).rounded()))) }
        try data.write(to: url)
    }

    /// 4 秒・10 fps・160x90 の MP4(秒ごとに色が変わる)。
    func makeVideo(_ name: String = "clip.mp4") async throws -> String {
        let url = dir.appendingPathComponent(name)
        let w = 160, h = 90, fps = 10, seconds = 4
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        writer.add(input)
        writer.startWriting(); writer.startSession(atSourceTime: .zero)
        let colors: [(UInt8, UInt8, UInt8)] = [(220, 60, 60), (60, 200, 90), (70, 110, 230), (230, 200, 60)]
        for f in 0..<(fps * seconds) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, nil, &pb)
            let buf = try XCTUnwrap(pb)
            CVPixelBufferLockBaseAddress(buf, [])
            let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
            let bpr = CVPixelBufferGetBytesPerRow(buf)
            let col = colors[(f / fps) % colors.count]
            for y in 0..<h { for x in 0..<w {
                let o = y * bpr + x * 4
                let shade = UInt8(min(255, Int(col.0) * (x + 40) / (w + 40)))
                base[o] = col.2; base[o + 1] = col.1; base[o + 2] = shade; base[o + 3] = 255
            } }
            CVPixelBufferUnlockBaseAddress(buf, [])
            adaptor.append(buf, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
        return url.path
    }

    private func clip(_ id: String, _ type: ClipType, src: String? = nil, start: Double, dur: Double, offset: Double = 0, srcDur: Double? = nil) -> Clip {
        var c = Clip(); c.id = id; c.type = type; c.src = src; c.start = start; c.duration = dur; c.offset = offset; c.srcDuration = srcDur
        return c
    }

    private func makeCanvas(_ m: ProjectModel, width: CGFloat = 1100, height: CGFloat = 330) -> (TimelineCanvas, NSWindow) {
        let canvas = TimelineCanvas(frame: NSRect(x: 0, y: 0, width: width, height: height))
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        canvas.model = m
        canvas.syncFromModel()
        return (canvas, window)
    }

    private func savePNG(_ view: NSView, _ name: String) throws -> URL {
        let url = URL(fileURLWithPath: Self.outDir).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        return url
    }

    // MARK: キャッシュ(裏で作る・待たせない)

    func testThumbnailsAndWaveformsAreBuiltInBackgroundAndNeverBlock() async throws {
        let png = try makePNG(), wav = try makeTone(), mp4 = try await makeVideo()
        let cache = TimelineMediaCache.shared
        // 最初の問い合わせはすぐ nil が返る(待たない)
        let t0 = CACurrentMediaTime()
        XCTAssertNil(cache.thumbnail(path: png, time: 0, isImage: true))
        XCTAssertNil(cache.thumbnail(path: mp4, time: 1.5, isImage: false))
        XCTAssertNil(cache.waveform(path: wav))
        XCTAssertLessThan(CACurrentMediaTime() - t0, 0.05, "UI を止めない")
        let idle = await cache.waitUntilIdle()
        XCTAssertTrue(idle)
        let still = try XCTUnwrap(cache.thumbnail(path: png, time: 0, isImage: true))
        XCTAssertLessThanOrEqual(max(still.width, still.height), 256, "低解像度")
        let frame = try XCTUnwrap(cache.thumbnail(path: mp4, time: 1.5, isImage: false))
        XCTAssertGreaterThan(frame.width, 0)
        let peaks = try XCTUnwrap(cache.waveform(path: wav))
        XCTAssertEqual(peaks.duration, 3, accuracy: 0.05)
        let cols = peaks.columns(from: 0, to: 3, count: 3)
        XCTAssertGreaterThan(cols[0], 0.6); XCTAssertLessThan(cols[1], 0.3); XCTAssertGreaterThan(cols[2], 0.6)
        // 音の無い素材(画像)・存在しない素材は「無い」と覚えて、何度も読みに行かない
        XCTAssertNil(cache.waveform(path: png))
        _ = await cache.waitUntilIdle()
        XCTAssertTrue(cache.hasNoAudio(path: png))
        XCTAssertNil(cache.thumbnail(path: "/nonexistent/x.mp4", time: 0, isImage: false))
        _ = await cache.waitUntilIdle()
        XCTAssertNil(cache.thumbnail(path: "/nonexistent/x.mp4", time: 0, isImage: false), "失敗は覚える")
        // ファイルが差し替わると別のものとして作り直す(更新日時が鍵に入る)
        let k1 = TimelineMediaCache.thumbKey(path: png, stamp: 100, time: 0), k2 = TimelineMediaCache.thumbKey(path: png, stamp: 200, time: 0)
        XCTAssertNotEqual(k1, k2)
    }

    // MARK: 絵(オフスクリーン)

    func testSnapshotTimelineWithThumbnailsWaveformsLayersAndSelection() async throws {
        let png = try makePNG(), wav = try makeTone(), mp4 = try await makeVideo()
        var p = Project.new()
        p.tracks[0].name = "映像"
        p.tracks[0].clips = [
            clip("img", .image, src: png, start: 0.5, dur: 3),
            clip("vid", .video, src: mp4, start: 4, dur: 4, srcDur: 4),
            clip("vrev", .video, src: mp4, start: 8.5, dur: 2, offset: 0, srcDur: 4),
        ]
        p.tracks[0].clips[2].reverse = true; p.tracks[0].clips[2].speed = 2
        p.tracks[1].name = "BGM"
        p.tracks[1].clips = [clip("bgm", .audio, src: wav, start: 0.5, dur: 3, srcDur: 3), clip("bgm2", .audio, src: wav, start: 4, dur: 1.5, offset: 0.5, srcDur: 3)]
        p.tracks[2].name = "字幕(ロック)"
        p.tracks[2].locked = true
        p.tracks[2].clips = [clip("tx", .text, start: 1, dur: 4)]
        p.tracks[2].clips[0].text = "こんにちは"
        p.tracks[3].name = "大きい行"
        p.tracks[3].height = "large"
        p.tracks[3].solo = true
        p.tracks[3].clips = [clip("big", .image, src: png, start: 2, dur: 6), clip("bigv", .video, src: mp4, start: 9, dur: 3, srcDur: 4)]
        p.tracks[4].name = "小さい行"
        p.tracks[4].height = "small"
        p.tracks[4].clips = [clip("sm", .audio, src: wav, start: 1, dur: 3, srcDur: 3)]
        let m = ProjectModel(project: p)
        m.snapEnabled = false
        m.pps = 70
        let (canvas, window) = makeCanvas(m, width: 1100, height: 330)
        _ = window
        m.setSelection(ClipSelection(ids: ["img", "bgm", "big"], primary: "img"))
        m.selectLayer(3)
        m.setSelection(ClipSelection(ids: ["img", "bgm", "big"], primary: "img"))
        canvas.syncFromModel()
        // 1 回目: まだ何も作られていない(クリップの色のまま)。描くのに時間をかけない
        canvas.setNeedsDisplay(canvas.bounds); canvas.display()
        let cold = canvas.lastDrawMs
        _ = try savePNG(canvas, "timeline-cold.png")
        let idle = await TimelineMediaCache.shared.waitUntilIdle(timeout: 20)
        XCTAssertTrue(idle)
        canvas.setNeedsDisplay(canvas.bounds); canvas.display()
        let warm = canvas.lastDrawMs
        let url = try savePNG(canvas, "timeline-media.png")
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertGreaterThan((attrs[.size] as? Int) ?? 0, 10_000)
        print("SNAPSHOT draw cold \(String(format: "%.2f", cold)) ms, warm \(String(format: "%.2f", warm)) ms -> \(url.path)")
        XCTAssertLessThan(warm, 100)
        // 描いたあと、サムネイルと波形がキャッシュに入っている
        XCTAssertNotNil(TimelineMediaCache.shared.thumbnail(path: png, time: 0, isImage: true))
        XCTAssertNotNil(TimelineMediaCache.shared.waveform(path: wav))
        m.shutdown()
    }

    func testSnapshotMultiSelectionInspectorAndRubberBand() async throws {
        var p = Project.new()
        p.tracks[0].clips = [clip("a", .text, start: 0.5, dur: 2), clip("b", .text, start: 3, dur: 2)]
        p.tracks[1].clips = [clip("c", .text, start: 1, dur: 2), clip("d", .blur, start: 4, dur: 2)]
        for i in 0..<4 { let t = i < 2 ? 0 : 1; let j = i % 2; p.tracks[t].clips[j].text = ["A", "B", "C", "D"][i] }
        let m = ProjectModel(project: p)
        m.pps = 80
        let (canvas, window) = makeCanvas(m, width: 760, height: 190)
        _ = window
        // ラバーバンドの途中(押したまま止める)
        let g = canvas.geometry
        let a = NSPoint(x: g.x(forTime: 0.2), y: g.rowTop(1) + 36), b = NSPoint(x: g.x(forTime: 3.6), y: g.rowTop(0) + 14)
        canvas.mouseDown(at: a)
        canvas.mouseDragged(to: NSPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2))
        canvas.mouseDragged(to: b)
        XCTAssertNotNil(canvas.rubber)
        XCTAssertTrue(canvas.rubber!.active)
        XCTAssertEqual(m.selectedClipIDs, ["a", "b", "c"])
        canvas.syncFromModel()
        canvas.setNeedsDisplay(canvas.bounds); canvas.display()
        _ = try savePNG(canvas, "timeline-rubber-band.png")
        canvas.mouseUp()

        // プロパティ欄(複数選択)
        let host = NSHostingView(rootView: InspectorView(model: m, speakers: AppServices.speakers).frame(width: 300, height: 260).background(Color(nsColor: .windowBackgroundColor)))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 260)
        let w2 = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w2.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        host.layoutSubtreeIfNeeded()
        _ = try savePNG(host, "inspector-multi.png")
        m.shutdown()
    }
}

/// 作れなかったもの(サムネイル・波形)の覚えは上限で止まる(長い編集の間に伸び続けない)。
@MainActor
final class TimelineMediaCacheBoundTests: XCTestCase {
    func testFailureMemoryIsCapped() {
        let c = TimelineMediaCache()
        for i in 0..<(TimelineMediaCache.maxFailed * 2 + 5) { c.recordFailure("path|\(i)") }
        XCTAssertLessThanOrEqual(c.failedCount, TimelineMediaCache.maxFailed)
        XCTAssertGreaterThan(c.failedCount, 0)
    }
}
