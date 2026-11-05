import XCTest
import AVFoundation
@testable import MovieCutCore

/// 音程変更(AudioFx.pitch → PitchShift)。合成した正弦波だけで確かめる(外部の素材なし、決定的)。
final class PitchShiftTests: XCTestCase {
    let sr = 48_000.0

    func sine(seconds: Double, f: Double) -> [Float] {
        (0..<Int(seconds * sr)).map { Float(0.5 * sin(2 * Double.pi * f * Double($0) / sr)) }
    }

    /// 区間内の上向きゼロ交差から求めた周波数(Hz)。
    func frequency(_ x: [Float], from a: Double, to b: Double) -> Double {
        let i0 = Int(a * sr), i1 = min(x.count - 1, Int(b * sr))
        var crossings = 0
        for i in (i0 + 1)..<i1 where x[i - 1] < 0 && x[i] >= 0 { crossings += 1 }
        return Double(crossings) / (b - a)
    }

    func testPlusTwelveSemitonesDoublesTheFrequency() {
        let x = sine(seconds: 2, f: 440)
        let y = PitchShift.shift(x, semitones: 12)
        let f = frequency(y, from: 0.25, to: 1.75)
        XCTAssertEqual(f, 880, accuracy: 880 * 0.03, "440 Hz を +12 半音で \(f) Hz に")
    }

    func testMinusTwelveSemitonesHalvesTheFrequency() {
        let y = PitchShift.shift(sine(seconds: 2, f: 440), semitones: -12)
        let f = frequency(y, from: 0.25, to: 1.75)
        XCTAssertEqual(f, 220, accuracy: 220 * 0.03, "440 Hz を −12 半音で \(f) Hz に")
    }

    func testSevenSemitonesMatchesEqualTemperament() {
        let y = PitchShift.shift(sine(seconds: 2, f: 440), semitones: 7)
        let expected = 440 * pow(2, 7.0 / 12)
        XCTAssertEqual(frequency(y, from: 0.25, to: 1.75), expected, accuracy: expected * 0.03)
    }

    func testDurationIsPreserved() {
        let x = sine(seconds: 2, f: 440)
        for s in [-12.0, -5, 0.5, 12] {
            XCTAssertEqual(PitchShift.shift(x, semitones: s).count, x.count, "半音 \(s)")
        }
    }

    func testZeroSemitonesIsBitIdentical() {
        let x = sine(seconds: 1, f: 300)
        XCTAssertEqual(PitchShift.shift(x, semitones: 0), x)
        XCTAssertEqual(PitchShift.shift([], semitones: 5), [])
    }

    func testOutputIsDeterministic() {
        let x = sine(seconds: 1, f: 300)
        XCTAssertEqual(PitchShift.shift(x, semitones: 4), PitchShift.shift(x, semitones: 4))
    }

    func testRenderFileKeepsFrameCountAndShiftsPitch() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pitch-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let src = dir.appendingPathComponent("in.caf")
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: 2, interleaved: false)!
        let x = sine(seconds: 2, f: 440)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(x.count))!
        buf.frameLength = AVAudioFrameCount(x.count)
        for c in 0..<2 { for i in 0..<x.count { buf.floatChannelData![c][i] = x[i] } }
        do {
            let f = try AVAudioFile(forWriting: src, settings: fmt.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try f.write(from: buf)
        }
        let outURL = try PitchShift.renderFile(from: src, semitones: 12, in: dir)
        let out = try AVAudioFile(forReading: outURL)
        XCTAssertEqual(out.length, AVAudioFramePosition(x.count), "長さは変わらない")
        let rd = AVAudioPCMBuffer(pcmFormat: out.processingFormat, frameCapacity: AVAudioFrameCount(x.count))!
        try out.read(into: rd)
        let left = Array(UnsafeBufferPointer(start: rd.floatChannelData![0], count: x.count))
        XCTAssertEqual(frequency(left, from: 0.25, to: 1.75), 880, accuracy: 880 * 0.03)
    }

    // MARK: 音声エフェクトの項目(保存・キャッシュ鍵・編集)

    func testPitchIsOptionalAndOnlyWrittenWhenNonZero() throws {
        var c = Clip(); c.type = .audio; c.src = "a.wav"; c.start = 0; c.duration = 1; c.srcDuration = 1
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(c), as: UTF8.self).contains("pitch"))
        XCTAssertTrue(AudioFxEditing.setPitch(&c, 5))
        XCTAssertEqual(c.audioFx?.pitch, 5)
        XCTAssertFalse(AudioFxEditing.setPitch(&c, 5), "同じ値は変化なし")
        XCTAssertTrue(AudioFxEditing.setPitch(&c, 99))
        XCTAssertEqual(c.audioFx?.pitch, 24, "−24〜+24 に収める")
        XCTAssertTrue(AudioFxEditing.setPitch(&c, 0))
        XCTAssertNil(c.audioFx, "0 に戻ったら項目ごと外す")
    }

    func testPitchRoundTripsAndCacheTokenChanges() throws {
        var fx = AudioFx()
        XCTAssertFalse(fx.isActive)
        let before = fx.cacheToken
        fx.pitch = -3.5
        XCTAssertTrue(fx.isActive)
        XCTAssertNotEqual(fx.cacheToken, before, "キャッシュ鍵に音程が入る")
        let text = String(decoding: try JSONEncoder().encode(fx), as: UTF8.self)
        XCTAssertTrue(text.contains("\"pitch\":-3.5"), text)
        let back = try JSONDecoder().decode(AudioFx.self, from: Data(text.utf8))
        XCTAssertEqual(back.pitch, -3.5)
    }

    func testBadTypedPitchIsKeptAsExtra() throws {
        let fx = try JSONDecoder().decode(AudioFx.self, from: Data(#"{"pitch":"high"}"#.utf8))
        XCTAssertNil(fx.pitch)
        XCTAssertEqual(fx.extra["pitch"], .string("high"))
    }

    // MARK: ±24 半音とセント(音MAD 向けの拡張)

    func testPlusTwentyFourQuadruplesAndMinusTwentyFourQuarters() {
        let x = sine(seconds: 2, f: 300)
        let up = PitchShift.shift(x, semitones: 24)
        XCTAssertEqual(up.count, x.count)
        XCTAssertEqual(frequency(up, from: 0.25, to: 1.75), 1200, accuracy: 1200 * 0.04)
        let down = PitchShift.shift(x, semitones: -24)
        XCTAssertEqual(down.count, x.count)
        XCTAssertEqual(frequency(down, from: 0.25, to: 1.75), 75, accuracy: 75 * 0.06)
    }

    func testCentsAreHonoured() {
        // +50 セント = 半音の半分
        let y = PitchShift.shift(sine(seconds: 2, f: 440), semitones: 0.5)
        let expected = 440 * pow(2, 0.5 / 12)
        XCTAssertEqual(frequency(y, from: 0.25, to: 1.75), expected, accuracy: expected * 0.02)
    }

    func testSetPitchKeepsOneCentResolution() {
        var c = Clip(); c.type = .audio; c.src = "a.wav"; c.start = 0; c.duration = 1; c.srcDuration = 1
        XCTAssertTrue(AudioFxEditing.setPitch(&c, 3.234))
        XCTAssertEqual(c.audioFx?.pitch ?? 0, 3.23, accuracy: 1e-9)
        XCTAssertTrue(AudioFxEditing.setPitch(&c, -24.5))
        XCTAssertEqual(c.audioFx?.pitch, -24)
        XCTAssertTrue(AudioFxEditing.setPitch(&c, 0.004), "0.4 セントは 0 に丸まる → 項目ごと外れる") 
        XCTAssertNil(c.audioFx)
    }

    func testSplitAndComposePitch() {
        for v in stride(from: -24.0, through: 24.0, by: 0.01) {
            let r = (v * 100).rounded() / 100
            let (st, ct) = AudioFx.splitPitch(r)
            XCTAssertTrue((-50...50).contains(ct), "\(r) → \(st), \(ct)")
            XCTAssertEqual(AudioFx.composePitch(semitones: st, cents: ct), r, accuracy: 1e-9)
        }
        XCTAssertTrue(AudioFx.splitPitch(3.2) == (3, 20))
        XCTAssertTrue(AudioFx.splitPitch(-2.6) == (-3, 40))
        XCTAssertEqual(AudioFx.composePitch(semitones: 24, cents: 50), 24, "範囲に収める")
    }

    func testOldFixtureRangeValuesUnchanged() throws {
        // 旧い範囲(±12)の値と 0.1 刻みの値は、そのまま同じ文字列で書き戻る
        for v in [-12.0, 7.5, 0.1, 12] {
            var fx = AudioFx(); fx.pitch = v
            let a = try JSONEncoder().encode(fx)
            let back = try JSONDecoder().decode(AudioFx.self, from: a)
            XCTAssertEqual(try JSONEncoder().encode(back), a)
        }
    }
}
