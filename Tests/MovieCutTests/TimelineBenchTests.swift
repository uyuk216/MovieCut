import XCTest
import AppKit
import MovieCutCore
@testable import MovieCut

/// タイムラインの再描画時間(クリップ 200 個)。数値は標準出力に出す(しきい値は緩い上限だけ)。
/// A6 の前(A5 の描画のまま)の同じ測り方: 中央値 3.81 ms(最小 3.64 / 最大 4.05)。
@MainActor
final class TimelineBenchTests: XCTestCase {
    private func project(media: (png: String, wav: String)?) -> Project {
        var p = Project.new()
        for t in 0..<5 {
            var clips: [Clip] = []
            for i in 0..<40 {
                var c = Clip()
                c.id = "c\(t)-\(i)"; c.start = Double(i) * 1.5; c.duration = 1.2
                c.type = [ClipType.video, .image, .audio, .text, .blur][t]
                if let m = media {
                    c.src = t == 1 ? m.png : (t < 3 ? m.wav : nil)
                } else {
                    c.src = t < 3 ? "/nonexistent/f\(t).mp4" : nil
                }
                c.srcDuration = 100
                c.text = t == 3 ? "テキスト\(i)" : nil
                clips.append(c)
            }
            p.tracks[t].clips = clips
        }
        return p
    }

    private func measure(_ p: Project, label: String) -> Double {
        let m = ProjectModel(project: p)
        m.pps = 40
        let canvas = TimelineCanvas(frame: NSRect(x: 0, y: 0, width: 1400, height: 260))
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        canvas.model = m
        canvas.syncFromModel()
        for _ in 0..<3 { canvas.setNeedsDisplay(canvas.bounds); canvas.display() }   // ウォームアップ
        var samples: [Double] = []
        for _ in 0..<30 { canvas.setNeedsDisplay(canvas.bounds); canvas.display(); samples.append(canvas.lastDrawMs) }
        samples.sort()
        let median = samples[samples.count / 2]
        print("BENCH \(label): median \(String(format: "%.2f", median)) ms, min \(String(format: "%.2f", samples[0])) ms, max \(String(format: "%.2f", samples.last!)) ms, drawn \(canvas.lastDrawClipCount)")
        m.shutdown()
        _ = window
        return median
    }

    func testRedrawTimeWith200Clips() throws {
        let median = measure(project(media: nil), label: "timeline redraw 200 clips (素材なし = A5 と同じ中身)")
        XCTAssertLessThan(median, 100)
    }

    /// 200 個のクリップが、実際にある画像(サムネイル)と WAV(波形)を使い、キャッシュが温まったあとの再描画。
    func testRedrawTimeWith200ClipsWithThumbnailsAndWaveformsReady() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("a6-bench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let helper = TimelineMediaTests()
        _ = helper
        let wav = dir.appendingPathComponent("t.wav")
        try TimelineMediaTests.writeWav(url: wav) { t in 0.6 * sin(2 * .pi * 330 * t) * (0.5 + 0.5 * sin(t * 6)) }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 160, pixelsHigh: 90, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for y in 0..<90 { for x in 0..<160 { rep.setColor(NSColor(calibratedRed: CGFloat(x) / 160, green: 0.5, blue: CGFloat(y) / 90, alpha: 1), atX: x, y: y) } }
        let png = dir.appendingPathComponent("p.png")
        try rep.representation(using: .png, properties: [:])!.write(to: png)
        let p = project(media: (png.path, wav.path))
        // 先に作らせる(キャッシュを温める)
        let m = ProjectModel(project: p)
        m.pps = 40
        let canvas = TimelineCanvas(frame: NSRect(x: 0, y: 0, width: 1400, height: 260))
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        canvas.model = m
        canvas.syncFromModel()
        TimelineMediaCache.shared.removeAll()
        canvas.setNeedsDisplay(canvas.bounds); canvas.display()
        let cold = canvas.lastDrawMs
        let idle = await TimelineMediaCache.shared.waitUntilIdle(timeout: 20)
        XCTAssertTrue(idle)
        for _ in 0..<3 { canvas.setNeedsDisplay(canvas.bounds); canvas.display() }
        var samples: [Double] = []
        for _ in 0..<30 { canvas.setNeedsDisplay(canvas.bounds); canvas.display(); samples.append(canvas.lastDrawMs) }
        samples.sort()
        let median = samples[samples.count / 2]
        print("BENCH timeline redraw 200 clips with thumbnails+waveforms ready: median \(String(format: "%.2f", median)) ms, min \(String(format: "%.2f", samples[0])) ms, max \(String(format: "%.2f", samples.last!)) ms (cold first draw \(String(format: "%.2f", cold)) ms), drawn \(canvas.lastDrawClipCount)")
        XCTAssertLessThan(median, 100)
        XCTAssertLessThan(cold, 100, "最初の 1 回(まだ何も無い)も待たない")
        m.shutdown()
        _ = window
    }
}
