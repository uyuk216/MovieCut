import XCTest
import AVFoundation
@testable import MovieCutCore

final class AudioMoraTimingTests: XCTestCase {
    let rate = 16000.0

    /// トーン区間と無音を交互に並べた合成音。runs = (秒, 鳴らすか)
    func synth(_ runs: [(Double, Bool)]) -> [Float] {
        var out: [Float] = []
        for (d, on) in runs {
            for i in 0..<Int(d * rate) { out.append(on ? 0.5 * sin(Float(i) * 2 * .pi * 220 / Float(rate)) : 0) }
        }
        return out
    }

    func writeWav(_ s: [Float], to url: URL) throws {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(s.count))!
        buf.frameLength = AVAudioFrameCount(s.count)
        for i in 0..<s.count { buf.floatChannelData![0][i] = s[i] }
        let f = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false])
        try f.write(from: buf)
    }

    func testBoundariesFromKnownTone() {
        // 0.2 無音 / 0.8 発音(4 拍 = 0.2 秒ずつ) / 0.5 無音
        let env = AudioMoraTiming.envelope(samples: synth([(0.2, false), (0.8, true), (0.5, false)]), sampleRate: rate)
        let moras: [Viseme] = [.a, .i, .u, .e]
        let segs = AudioMoraTiming.segments(moras: moras, envelope: env)
        XCTAssertEqual(segs.map(\.vowel), moras)
        for (k, s) in segs.enumerated() {
            XCTAssertEqual(s.start, 0.2 + 0.2 * Double(k), accuracy: 0.03)
            XCTAssertEqual(s.end, 0.2 + 0.2 * Double(k + 1), accuracy: 0.03)
        }
    }

    func testSilenceGapIsSkippedAndShortGapIsFilled() {
        // 0.4 発音 / 0.5 無音(読点) / 0.4 発音 の途中に 0.05 の谷(促音相当、埋まる)
        let env = AudioMoraTiming.envelope(samples: synth([(0.2, true), (0.05, false), (0.2, true), (0.5, false), (0.4, true)]), sampleRate: rate)
        let r = AudioMoraTiming.voicedRanges(envelope: env)
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(r[0].end, 0.45, accuracy: 0.03)
        XCTAssertEqual(r[1].start, 0.95, accuracy: 0.03)
        let segs = AudioMoraTiming.segments(moras: [.a, .i, .u, .e], envelope: env)
        // 無音区間にはどの口形も置かない
        XCTAssertTrue(segs.allSatisfy { $0.end <= r[0].end + 1e-9 || $0.start >= r[1].start - 1e-9 })
        XCTAssertEqual(segs.last!.end, r[1].end, accuracy: 0.03)
    }

    func testClosedMoraTakesTimeButEmitsNoSegment() {
        let env = AudioMoraTiming.envelope(samples: synth([(0.6, true)]), sampleRate: rate)
        let segs = AudioMoraTiming.segments(moras: [.a, .closed, .i], envelope: env)
        XCTAssertEqual(segs.map(\.vowel), [.a, .i])
        XCTAssertEqual(segs[0].end, 0.2, accuracy: 0.03)
        XCTAssertEqual(segs[1].start, 0.4, accuracy: 0.03)
    }

    func testKanaToVisemes() {
        XCTAssertEqual(LipSync.moras(of: "こんにちは"), [.o, .closed, .i, .i, .a])
        XCTAssertEqual(LipSync.moras(of: "きゃっとー"), [.a, .closed, .o, .o])
        XCTAssertEqual(LipSync.moras(of: "カタカナ"), [.a, .a, .a, .a])
    }

    func testSilentOrEmptyInputGivesNothing() {
        XCTAssertTrue(AudioMoraTiming.segments(moras: [.a], envelope: [0, 0, 0]).isEmpty)
        XCTAssertTrue(AudioMoraTiming.segments(moras: [], envelope: [1, 1, 1]).isEmpty)
        XCTAssertTrue(AudioMoraTiming.envelope(samples: [], sampleRate: rate).isEmpty)
    }

    func testSidecarRoundTripAndRenderCompatibility() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("amt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("a.wav")
        try writeWav(synth([(0.1, false), (0.6, true), (0.1, false)]), to: wav)
        XCTAssertTrue(AudioMoraTiming.writeSidecar(wav: wav, text: "あいう"))
        let data = try Data(contentsOf: VoicevoxMora.sidecarURL(forWav: wav.path))
        let segs = try XCTUnwrap(VoicevoxMora.decodeSidecar(data))   // VOICEVOX と同じ読み取りで読める
        XCTAssertEqual(segs.map(\.vowel), [.a, .i, .u])
        XCTAssertEqual(segs[0].start, 0.1, accuracy: 0.04)
        XCTAssertEqual(VoicevoxMora.encodeSidecar(segs), VoicevoxMora.encodeSidecar(VoicevoxMora.decodeSidecar(data)!))
        // 2 回目は既存が有効なので何もしない
        XCTAssertFalse(AudioMoraTiming.writeSidecar(wav: wav, text: "あいう"))
        // RenderAssets 経由でサイドカーが使われる(コマの口形が母音順になる)
        let assets = RenderAssets()
        let v = try XCTUnwrap(assets.visemes(src: wav.path, text: "あいう", offset: 0, duration: 0.8))
        XCTAssertEqual(v[Int(0.2 * 60)], .a)
        XCTAssertEqual(v[Int(0.4 * 60)], .i)
        XCTAssertEqual(v[Int(0.6 * 60)], .u)
        XCTAssertEqual(v[1], .closed)
    }

    func testFallbackWithoutWavOrKana() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("amt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let missing = dir.appendingPathComponent("none.wav")
        XCTAssertNil(AudioMoraTiming.timeline(wav: missing, text: "あいう"))
        XCTAssertFalse(AudioMoraTiming.writeSidecar(wav: missing, text: "あいう"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: VoicevoxMora.sidecarURL(forWav: missing.path).path))
        let wav = dir.appendingPathComponent("b.wav")
        try writeWav(synth([(0.5, true)]), to: wav)
        XCTAssertFalse(AudioMoraTiming.writeSidecar(wav: wav, text: "、。"))   // カナ無し
        XCTAssertFalse(FileManager.default.fileExists(atPath: VoicevoxMora.sidecarURL(forWav: wav.path).path))
        // サイドカー無しの visemes は従来の LipSync.frames と一致
        let assets = RenderAssets()
        let got = assets.visemes(src: wav.path, text: "あいう", offset: 0, duration: 0.5)
        let env = try XCTUnwrap(assets.mouthEnvelope(for: wav.path))
        XCTAssertEqual(got, LipSync.frames(moras: LipSync.moras(of: "あいう"), envelope: env, range: 0..<Int(ceil(0.5 * 60))))
    }
}
