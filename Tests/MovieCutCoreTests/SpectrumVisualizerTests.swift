import XCTest
import CoreGraphics
@testable import MovieCutCore

/// 音声ビジュアライザの「スペクトル」モードと、音声クリップごとの入力。
final class SpectrumVisualizerTests: XCTestCase {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("spectrum-viz-tests-\(UUID().uuidString)")
    override func setUpWithError() throws { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    static let W = 400, H = 200

    func sine(_ f: Double, seconds: Double, amp: Float = 0.5, sr: Double = 48000) -> [Float] {
        (0..<Int(seconds * sr)).map { amp * Float(sin(2 * .pi * f * Double($0) / sr)) }
    }

    func argmax(_ a: ArraySlice<Float>) -> Int { a.enumerated().max { $0.element < $1.element }!.offset }

    // MARK: 解析(合成した正弦波)

    func testBandIndexIsLogSpaced() {
        XCTAssertEqual(SpectrumAnalyzer.bandIndex(for: 440, count: 32), 12)
        XCTAssertEqual(SpectrumAnalyzer.bandIndex(for: 4000, count: 32), 24)
        XCTAssertEqual(SpectrumAnalyzer.bandIndex(for: 1, count: 32), 0)
        XCTAssertEqual(SpectrumAnalyzer.bandIndex(for: 100000, count: 32), 31)
        // 帯の境目は 40 Hz 〜 16 kHz を対数に等分
        let e = SpectrumAnalyzer.bandEdges(count: 8)
        XCTAssertEqual(e.first!, 40, accuracy: 1e-9)
        XCTAssertEqual(e.last!, 16000, accuracy: 1e-6)
        XCTAssertEqual(e[2] / e[1], e[5] / e[4], accuracy: 1e-9)
    }

    func testSineLandsInTheExpectedBand() {
        for (f, count) in [(440.0, 32), (4000.0, 32), (440.0, 64), (4000.0, 16), (100.0, 32), (10000.0, 32)] {
            let out = SpectrumAnalyzer.analyze(mono: sine(f, seconds: 1), sampleRate: 48000, count: count, frames: 60)
            let k = 40
            let row = out[(k * count)..<((k + 1) * count)]
            let got = argmax(row)
            let want = SpectrumAnalyzer.bandIndex(for: f, count: count)
            XCTAssertEqual(got, want, "\(f) Hz / \(count) 本: 最大の帯 \(got) 期待 \(want)")
            XCTAssertGreaterThan(row.max()!, 0.8, "振幅 0.5(−6 dBFS)は 0.9 付近: \(row.max()!)")
        }
    }

    func testFarBandsStayLowForPureTone() {
        let count = 32
        let out = SpectrumAnalyzer.analyze(mono: sine(440, seconds: 1), sampleRate: 48000, count: count, frames: 60)
        let row = Array(out[(40 * count)..<(41 * count)])
        XCTAssertLessThan(row[24], 0.1, "4 kHz の帯は 440 Hz の音ではほぼ無音: \(row[24])")
        XCTAssertLessThan(row[2], 0.2)
    }

    func testSilenceIsZeroAndAnalysisIsDeterministic() {
        let zero = SpectrumAnalyzer.analyze(mono: [Float](repeating: 0, count: 48000), sampleRate: 48000, count: 16, frames: 30)
        XCTAssertEqual(zero.max(), 0)
        let s = sine(1000, seconds: 0.5) + sine(2500, seconds: 0.5)
        let a = SpectrumAnalyzer.analyze(mono: s, sampleRate: 48000, count: 24, frames: 60)
        let b = SpectrumAnalyzer.analyze(mono: s, sampleRate: 48000, count: 24, frames: 60)
        XCTAssertEqual(a, b, "同じ入力は同じ結果")
    }

    func testDecaySmoothingFallsGraduallyAfterToneStops() {
        let count = 32
        let s = sine(440, seconds: 0.5) + [Float](repeating: 0, count: 48000)
        let out = SpectrumAnalyzer.analyze(mono: s, sampleRate: 48000, count: count, frames: 90)
        let band = SpectrumAnalyzer.bandIndex(for: 440, count: count)
        let v = (0..<90).map { out[$0 * count + band] }
        let stop = 30 + 3   // 0.5 秒 = コマ 30(窓の半分ぶん後から下がり始める)
        XCTAssertGreaterThan(v[stop + 2], v[stop + 8], "ゆっくり下がる")
        XCTAssertGreaterThan(v[stop + 8], 0, "すぐには 0 にならない")
        for k in (stop + 1)..<89 { XCTAssertGreaterThanOrEqual(v[k] + 1e-6, v[k + 1], "下がるだけ(コマ \(k))") }
        XCTAssertLessThan(v[89], 0.05)
    }

    func testAnalysisSpeedMsPerFrame() {
        let s = sine(440, seconds: 10)
        let frames = 600
        let t0 = Date()
        _ = SpectrumAnalyzer.analyze(mono: s, sampleRate: 48000, count: 64, frames: frames)
        let msPerFrame = Date().timeIntervalSince(t0) * 1000 / Double(frames)
        print("[perf] スペクトル解析 \(String(format: "%.3f", msPerFrame)) ms/コマ(64 本、2048 点 FFT)")
        XCTAssertLessThan(msPerFrame, 2, "1 コマの解析は数 ms 未満")
    }

    // MARK: 設定の保存

    func testFieldsAreOptionalAndRoundTrip() throws {
        var c = ClipEditing.makeVisualizerClip(at: 0, project: Project())
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(c), as: UTF8.self).contains("spectrum"))
        c.visualizer = Visualizer(mode: "spectrum", source: "abc")
        let text = String(decoding: try JSONEncoder().encode(c), as: UTF8.self)
        XCTAssertTrue(text.contains("\"mode\":\"spectrum\""))
        XCTAssertTrue(text.contains("\"source\":\"abc\""))
        let back = try JSONDecoder().decode(Clip.self, from: Data(text.utf8))
        XCTAssertEqual(back.visualizer, Visualizer(mode: "spectrum", source: "abc"))
        XCTAssertTrue(back.visualizerOrDefault.isSpectrum)
        XCTAssertEqual(Visualizer(mode: "weird").modeOrDefault, "level", "知らない見方は音量")
        XCTAssertFalse(Visualizer().isSpectrum)
    }

    // MARK: 描画(プレビューと書き出しは同じ Renderer)

    func writeTone(_ name: String, f: Double, amp: Float = 0.5, seconds: Double = 1) throws -> String {
        let url = tmp.appendingPathComponent(name)
        try AudioFixture.writeSine(url, sampleRate: 24000, frequency: f, segments: [(seconds, amp)])
        return url.path
    }

    func project(_ clips: [Clip]) -> Project {
        var p = Project()
        p.width = Self.W; p.height = Self.H; p.bg = "#000000"
        var tr = Track(name: "L1"); tr.clips = clips
        p.tracks = [tr]
        return p
    }

    func viz(count: Int = 32, spectrum: Bool = true, source: String? = nil) -> Clip {
        var c = ClipEditing.makeVisualizerClip(at: 0, project: Project())
        c.duration = 1; c.x = 0.5; c.y = 0.85; c.w = 0.6; c.h = 0.2
        c.visualizer = Visualizer(color: "#ffffff", count: count, mode: spectrum ? "spectrum" : nil, source: source)
        return c
    }

    func audio(_ id: String, _ path: String, start: Double = 0) -> Clip {
        var c = Clip(); c.id = id; c.type = .audio; c.start = start; c.duration = 1; c.src = path
        return c
    }

    func heights(_ p: Project, count: Int, t: Double = 0.5) throws -> [Int] {
        let img = try XCTUnwrap(Renderer(project: p, assets: RenderAssets()).renderImage(t: t))
        var d = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let ctx = CGContext(data: &d, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return (0..<count).map { i in
            let x = Int((80 + 240.0 / Double(count) * (Double(i) + 0.5)).rounded())
            var n = 0, y = 189
            while y >= 0 {
                let o = (y * img.width + x) * 4
                if Int(d[o]) + Int(d[o + 1]) + Int(d[o + 2]) < 60 { break }
                n += 1; y -= 1
            }
            return n
        }
    }

    func testRenderedSpectrumPeaksAtToneBand() throws {
        let count = 32
        let low = try heights(project([viz(count: count), audio("a", try writeTone("440.wav", f: 440))]), count: count)
        let high = try heights(project([viz(count: count), audio("a", try writeTone("4k.wav", f: 4000))]), count: count)
        XCTAssertEqual(low.enumerated().max { $0.element < $1.element }!.offset, SpectrumAnalyzer.bandIndex(for: 440, count: count), "440 Hz: \(low)")
        XCTAssertEqual(high.enumerated().max { $0.element < $1.element }!.offset, SpectrumAnalyzer.bandIndex(for: 4000, count: count), "4 kHz: \(high)")
        XCTAssertGreaterThan(low[12], 30)
        XCTAssertLessThanOrEqual(low[24], 6, "遠い帯は低い: \(low)")
        // 同じ描画を 2 回: 画素まで同じ(決定的)
        let again = try heights(project([viz(count: count), audio("a", try writeTone("440.wav", f: 440))]), count: count)
        XCTAssertEqual(low, again)
    }

    func testPerClipSourceIgnoresTheOtherClips() throws {
        let count = 32
        let a = audio("tone440", try writeTone("440.wav", f: 440))
        let b = audio("tone4k", try writeTone("4k.wav", f: 4000))
        let p440 = project([viz(count: count, source: "tone440"), a, b])
        let p4k = project([viz(count: count, source: "tone4k"), a, b])
        let mixed = project([viz(count: count), a, b])
        let h440 = try heights(p440, count: count), h4k = try heights(p4k, count: count), hm = try heights(mixed, count: count)
        XCTAssertEqual(h440.enumerated().max { $0.element < $1.element }!.offset, 12)
        XCTAssertEqual(h4k.enumerated().max { $0.element < $1.element }!.offset, 24)
        XCTAssertGreaterThan(hm[12], 25, "全体のミックスは両方の音が出る: \(hm)")
        XCTAssertGreaterThan(hm[24], 25, "全体のミックスは両方の音が出る: \(hm)")
        XCTAssertLessThanOrEqual(h440[24], 6, "選んだクリップだけ: \(h440)")
        // 見つからないクリップはミックスに戻る
        let lost = try heights(project([viz(count: count, source: "gone"), a, b]), count: count)
        XCTAssertEqual(lost, hm)
    }

    func testLevelModeAlsoFollowsSelectedClip() throws {
        let loud = audio("loud", try writeTone("loud.wav", f: 440, amp: 0.5))
        var quiet = audio("quiet", try writeTone("quiet.wav", f: 440, amp: 0.001))
        quiet.start = 0
        let only = try heights(project([viz(count: 8, spectrum: false, source: "quiet"), loud, quiet]), count: 8)
        let all = try heights(project([viz(count: 8, spectrum: false), loud, quiet]), count: 8)
        XCTAssertLessThanOrEqual(only[0], 3, "静かなクリップだけを見ている: \(only)")
        XCTAssertGreaterThan(all[0], 25, "ミックス全体は大きい: \(all)")
    }

    func testRenderMsPerFrameWithSpectrum() throws {
        let p = project([viz(count: 64), audio("a", try writeTone("440.wav", f: 440, seconds: 3))])
        var proj = p; proj.tracks[0].clips[0].duration = 3
        let r = Renderer(project: proj, assets: RenderAssets())
        _ = r.renderImage(t: 0.1)   // 解析を済ませる
        let t0 = Date()
        let n = 60
        for i in 0..<n { _ = r.renderImage(t: 0.2 + Double(i) / 60) }
        let ms = Date().timeIntervalSince(t0) * 1000 / Double(n)
        print("[perf] スペクトルビジュアライザの描画 \(String(format: "%.2f", ms)) ms/コマ(400×200)")
        XCTAssertLessThan(ms, 20)
    }
}
