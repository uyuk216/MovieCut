import XCTest
import AVFoundation
@testable import MovieCutCore

/// 無音カット: 無音の検出(しきい値・最短の長さ・余白)、WAV を読んだ解析、クリップの切り分け(後ろを詰める / 詰めない)。
final class SilenceTests: XCTestCase {
    let sr = 48000.0
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("silence-tests-\(UUID().uuidString)")
    override func setUpWithError() throws { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    /// segments: (秒, 振幅)。振幅 0 は無音。
    func samples(_ segments: [(Double, Float)], f: Double = 300) -> [Float] {
        var out: [Float] = []
        var i = 0
        for (d, a) in segments {
            for _ in 0..<Int(d * sr) { out.append(a * Float(sin(2 * .pi * f * Double(i) / sr))); i += 1 }
        }
        return out
    }

    func profile(_ segments: [(Double, Float)]) -> LevelProfile {
        SilenceDetector.profile(left: samples(segments), sampleRate: sr)
    }

    func assertRanges(_ got: [SilenceRange], _ want: [(Double, Double)], accuracy: Double = 0.011, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(got.count, want.count, "\(got)", file: file, line: line)
        for (g, w) in zip(got, want) {
            XCTAssertEqual(g.start, w.0, accuracy: accuracy, file: file, line: line)
            XCTAssertEqual(g.end, w.1, accuracy: accuracy, file: file, line: line)
        }
    }

    // MARK: 検出

    func testDetectsMiddleSilenceWithPadAndIgnoresShortGap() {
        // 音 1 秒 / 無音 1.5 秒 / 音 1 秒 / 無音 0.2 秒(短い) / 音 0.8 秒 / 無音 1.5 秒(終わり)
        let p = profile([(1, 0.3), (1.5, 0), (1, 0.3), (0.2, 0), (0.8, 0.3), (1.5, 0)])
        XCTAssertEqual(p.duration, 6, accuracy: 1e-9)
        let silent = p.silentRanges(SilenceParams(thresholdDb: -40, minSilence: 0.4, pad: 0.1))
        // 中の無音 1.0–2.5 は両端に 0.1 秒残して 1.1–2.4。終わりの無音 4.5–6.0 は、クリップの終わり側には余白を残さない
        assertRanges(silent, [(1.1, 2.4), (4.6, 6.0)])
        assertRanges(p.keepRanges(SilenceParams(thresholdDb: -40, minSilence: 0.4, pad: 0.1)), [(0, 1.1), (2.4, 4.6)])
    }

    func testLeadingSilenceHasNoPadOnClipEdge() {
        let p = profile([(1, 0), (1, 0.3)])
        assertRanges(p.silentRanges(SilenceParams(thresholdDb: -40, minSilence: 0.4, pad: 0.1)), [(0, 0.9)])
    }

    func testThresholdMinSilenceAndPad() {
        // 小さい音(−40 dBFS 付近。振幅 0.014 → RMS ≈ −40 dB)を挟む
        let p = profile([(1, 0.3), (1, 0.003), (1, 0.3)])    // 0.003 → RMS ≈ −53 dB
        XCTAssertEqual(p.silentRanges(SilenceParams(thresholdDb: -60, minSilence: 0.4, pad: 0.1)).count, 0, "しきい値より大きい音は無音ではない")
        assertRanges(p.silentRanges(SilenceParams(thresholdDb: -45, minSilence: 0.4, pad: 0.1)), [(1.1, 1.9)])
        // 最短の無音が無音より長ければ切らない
        XCTAssertEqual(p.silentRanges(SilenceParams(thresholdDb: -45, minSilence: 1.5, pad: 0.1)).count, 0)
        // 余白が大きくて残らないものは捨てる(無音 1 秒、余白 0.5 秒ずつ → 残り 0 → 捨てる)
        XCTAssertEqual(p.silentRanges(SilenceParams(thresholdDb: -45, minSilence: 0.4, pad: 0.5)).count, 0)
        assertRanges(p.silentRanges(SilenceParams(thresholdDb: -45, minSilence: 0.4, pad: 0)), [(1, 2)])
    }

    func testAllSilentAndAllLoud() {
        let quiet = profile([(2, 0)])
        assertRanges(quiet.silentRanges(.default), [(0, 2)])
        XCTAssertTrue(profile([(2, 0.3)]).silentRanges(.default).isEmpty)
        XCTAssertEqual(SilenceDetector.keepRanges(silent: [], duration: 2), [SilenceRange(start: 0, end: 2)])
    }

    func testStereoUsesLouderChannel() {
        let l = [Float](repeating: 0, count: 48000)
        let r = samples([(1, 0.3)])
        XCTAssertTrue(SilenceDetector.profile(left: l, right: r, sampleRate: sr).silentRanges(.default).isEmpty)
        XCTAssertEqual(SilenceDetector.profile(left: l, right: l, sampleRate: sr).silentRanges(.default).count, 1)
    }

    func testParamsClamp() {
        let c = SilenceParams(thresholdDb: -500, minSilence: -3, pad: .nan).clamped
        XCTAssertEqual(c.thresholdDb, -80); XCTAssertEqual(c.minSilence, 0.05); XCTAssertEqual(c.pad, 0.1)
    }

    // MARK: ファイルを読んだ解析(ミキサーと同じ読み方)

    func writeWav(_ name: String, segments: [(Double, Float)], channels: Int = 2, rate: Double = 44100) throws -> String {
        let url = tmp.appendingPathComponent(name)
        try AudioFixture.writeSine(url, sampleRate: rate, channels: channels, frequency: 300, segments: segments)
        return url.path
    }

    func audioClip(_ path: String, start: Double = 0, duration: Double, offset: Double = 0, type: ClipType = .audio) -> Clip {
        var c = Clip(); c.type = type; c.src = path; c.start = start; c.duration = duration; c.offset = offset; c.srcDuration = duration + offset; c.volume = 1
        return c
    }

    func testAnalyzeWavMatchesSegments() throws {
        for (ch, rate) in [(1, 24000.0), (2, 44100.0), (2, 48000.0)] {
            let path = try writeWav("a\(ch)-\(Int(rate)).wav", segments: [(1, 0.3), (1.5, 0), (1, 0.3), (0.2, 0), (0.8, 0.3), (1.5, 0)], channels: ch, rate: rate)
            let prof = try XCTUnwrap(SilenceDetector.analyze(clip: audioClip(path, duration: 6)))
            assertRanges(prof.silentRanges(.default), [(1.1, 2.4), (4.6, 6.0)], accuracy: 0.03)
        }
    }

    func testAnalyzeRespectsOffsetAndDuration() throws {
        let path = try writeWav("off.wav", segments: [(1, 0.3), (2, 0), (1, 0.3)])
        // 素材の 0.5 秒から 2 秒分: 音 0.5 / 無音 1.5 → 無音は 0.6〜2.0
        let prof = try XCTUnwrap(SilenceDetector.analyze(clip: audioClip(path, duration: 2, offset: 0.5)))
        assertRanges(prof.silentRanges(.default), [(0.6, 2.0)], accuracy: 0.03)
    }

    func testAnalyzeUnsupportedReturnsNil() throws {
        let path = try writeWav("x.wav", segments: [(1, 0.3)])
        var fast = audioClip(path, duration: 1); fast.speed = 2
        XCTAssertNil(SilenceDetector.analyze(clip: fast))
        var rev = audioClip(path, duration: 1); rev.reverse = true
        XCTAssertNil(SilenceDetector.analyze(clip: rev))
        XCTAssertNil(SilenceDetector.analyze(clip: audioClip("/tmp/__no_such_file__.wav", duration: 1)))
        var img = Clip(); img.type = .image; img.src = path; img.duration = 1
        XCTAssertFalse(SilenceDetector.supports(img))
        XCTAssertTrue(SilenceDetector.supports(audioClip(path, duration: 1, type: .voice)))
    }

    // MARK: クリップの切り分け

    func project(_ clips: [Clip], second: [Clip] = []) -> Project {
        var p = Project(); p.tracks = [Track(name: "A"), Track(name: "B")]
        p.tracks[0].clips = clips; p.tracks[1].clips = second
        return p
    }

    func testRemoveSilenceSplitsAndRipples() throws {
        var c = audioClip("/x.wav", start: 2, duration: 6, offset: 1); c.id = "main"
        var after = audioClip("/y.wav", start: 8, duration: 2); after.id = "after"
        var other = audioClip("/o.wav", start: 9, duration: 1); other.id = "other"           // ほかのレイヤー: 動かさない
        let p = project([c, after], second: [other])
        // クリップの 1.0–2.5 と 4.5–6.0 を切る(余白は引いた後の範囲)
        let cuts = [SilenceRange(start: 1.1, end: 2.4), SilenceRange(start: 4.6, end: 6.0)]
        let r = try XCTUnwrap(ClipEditing.removeSilence(in: p, clipId: "main", cuts: cuts, ripple: true))
        let t0 = r.project.tracks[0].clips
        XCTAssertEqual(r.clipIds.count, 2)
        XCTAssertEqual(r.clipIds[0], "main")
        let a = try XCTUnwrap(t0.first { $0.id == r.clipIds[0] }), b = try XCTUnwrap(t0.first { $0.id == r.clipIds[1] })
        // 残る範囲: 0–1.1 と 2.4–4.6。詰めると 2.0〜3.1、3.1〜5.3
        XCTAssertEqual(a.start, 2, accuracy: 1e-9); XCTAssertEqual(a.duration, 1.1, accuracy: 1e-9); XCTAssertEqual(a.offset, 1, accuracy: 1e-9)
        XCTAssertEqual(b.start, 3.1, accuracy: 1e-9); XCTAssertEqual(b.duration, 2.2, accuracy: 1e-9); XCTAssertEqual(b.offset, 1 + 2.4, accuracy: 1e-9)
        // 後ろのクリップは、取り除いた長さ(2.7 秒)だけ左へ
        XCTAssertEqual(try XCTUnwrap(t0.first { $0.id == "after" }).start, 8 - 2.7, accuracy: 1e-9)
        XCTAssertEqual(r.project.tracks[1].clips[0].start, 9)
        XCTAssertEqual(t0.count, 3)
        XCTAssertNotEqual(a.id, b.id)
    }

    func testRemoveSilenceWithoutRippleKeepsPositions() throws {
        var c = audioClip("/x.wav", start: 0, duration: 6); c.id = "main"
        var after = audioClip("/y.wav", start: 6, duration: 2); after.id = "after"
        let p = project([c, after])
        let r = try XCTUnwrap(ClipEditing.removeSilence(in: p, clipId: "main", cuts: [SilenceRange(start: 1, end: 2)], ripple: false))
        let t0 = r.project.tracks[0].clips
        XCTAssertEqual(t0.count, 3)
        XCTAssertEqual(t0[0].start, 0); XCTAssertEqual(t0[0].duration, 1, accuracy: 1e-9)
        XCTAssertEqual(t0[1].start, 2, accuracy: 1e-9); XCTAssertEqual(t0[1].duration, 4, accuracy: 1e-9); XCTAssertEqual(t0[1].offset, 2, accuracy: 1e-9)
        XCTAssertEqual(t0[2].start, 6)
    }

    func testRemoveSilenceLeadingAndTrailing() throws {
        var c = audioClip("/x.wav", start: 1, duration: 6); c.id = "main"; c.fadeIn = 0.5; c.fadeOut = 0.5
        let p = project([c])
        let r = try XCTUnwrap(ClipEditing.removeSilence(in: p, clipId: "main", cuts: [SilenceRange(start: 0, end: 1), SilenceRange(start: 5, end: 6)], ripple: true))
        let only = try XCTUnwrap(r.project.tracks[0].clips.first)
        XCTAssertEqual(r.project.tracks[0].clips.count, 1)
        XCTAssertEqual(only.id, "main")
        XCTAssertEqual(only.start, 1, accuracy: 1e-9); XCTAssertEqual(only.duration, 4, accuracy: 1e-9); XCTAssertEqual(only.offset, 1, accuracy: 1e-9)
    }

    func testNoOpCases() {
        var c = audioClip("/x.wav", start: 0, duration: 4); c.id = "main"
        let p = project([c])
        XCTAssertNil(ClipEditing.removeSilence(in: p, clipId: "main", cuts: [], ripple: true))
        XCTAssertNil(ClipEditing.removeSilence(in: p, clipId: "main", cuts: [SilenceRange(start: 5, end: 6)], ripple: true), "クリップの外")
        XCTAssertNil(ClipEditing.removeSilence(in: p, clipId: "main", cuts: [SilenceRange(start: 0, end: 4)], ripple: true), "全部が無音なら切らない")
        XCTAssertNil(ClipEditing.removeSilence(in: p, clipId: "nope", cuts: [SilenceRange(start: 1, end: 2)], ripple: true))
        var fast = c; fast.speed = 2
        XCTAssertNil(ClipEditing.removeSilence(in: project([fast]), clipId: "main", cuts: [SilenceRange(start: 1, end: 2)], ripple: true))
    }

    func testVoiceClipKeepsKeyframesAcrossPieces() throws {
        var c = audioClip("/x.wav", start: 0, duration: 6, type: .voice); c.id = "v"
        c.keyframes["volume"] = [Keyframe(t: 0, v: 0.2), Keyframe(t: 6, v: 1)]
        let r = try XCTUnwrap(ClipEditing.removeSilence(in: project([c]), clipId: "v", cuts: [SilenceRange(start: 2, end: 3)], ripple: true))
        let pieces = r.project.tracks[0].clips
        XCTAssertEqual(pieces.count, 2)
        XCTAssertEqual(pieces.map(\.type), [.voice, .voice])
        XCTAssertTrue(pieces.allSatisfy { $0.hasVolumeKeys })
        // 音量の線は音に付いたまま: 右の断片の頭(元の 3 秒)の値 = 元の線の 3 秒の値
        let right = pieces[1]
        XCTAssertEqual(Animation.value(of: "volume", in: right, at: 0), 0.2 + 0.8 * 0.5, accuracy: 1e-6)
    }

    func testEndToEndWavToCutProject() throws {
        let path = try writeWav("e2e.wav", segments: [(1, 0.3), (1.5, 0), (1, 0.3), (0.2, 0), (0.8, 0.3), (1.5, 0)], channels: 2, rate: 48000)
        var c = audioClip(path, start: 0, duration: 6); c.id = "main"
        let prof = try XCTUnwrap(SilenceDetector.analyze(clip: c))
        let r = try XCTUnwrap(ClipEditing.removeSilence(in: project([c]), clipId: "main", cuts: prof.silentRanges(.default), ripple: true))
        let total = r.project.tracks[0].clips.reduce(0) { $0 + $1.duration }
        XCTAssertEqual(total, 6 - 2.7, accuracy: 0.05)
        // 書き出した音声も短くなる
        let out = tmp.appendingPathComponent("cut.caf")
        let dur = try AudioMixer.mixdown(project: r.project, assets: RenderAssets(), to: out)
        XCTAssertEqual(dur, 6 - 2.7, accuracy: 0.05)
    }
}
