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
        XCTAssertEqual(c.audioFx?.pitch, 12, "−12〜+12 に収める")
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
}
