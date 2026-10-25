import XCTest
import AVFoundation
@testable import YukkuriCore

/// テスト用の音声ヘルパー(AudioMixerTests と ExporterTests で共有)
enum AudioFixture {
    /// 一定振幅の正弦波 WAV。segments は (秒, 振幅) の並び(区間ごとに振幅を変えられる)。
    static func writeSine(_ url: URL, sampleRate: Double = 24000, channels: Int = 1, frequency: Double = 440, segments: [(Double, Float)]) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let total = segments.reduce(0) { $0 + Int($1.0 * sampleRate) }
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(total))!
        buf.frameLength = AVAudioFrameCount(total)
        var i = 0
        for (dur, amp) in segments {
            for _ in 0..<Int(dur * sampleRate) {
                let v = amp * Float(sin(2 * .pi * frequency * Double(i) / sampleRate))
                for c in 0..<channels { buf.floatChannelData![c][i] = v }
                i += 1
            }
        }
        try file.write(from: buf)
    }

    /// ミックス結果の [from, to) 秒のピーク(左右の大きい方)
    static func peak(_ url: URL, from: Double, to: Double) throws -> Float {
        let f = try AVAudioFile(forReading: url)
        let sr = f.processingFormat.sampleRate
        f.framePosition = AVAudioFramePosition(from * sr)
        let n = AVAudioFrameCount((to - from) * sr)
        let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: n)!
        try f.read(into: buf, frameCount: n)
        var m: Float = 0
        for c in 0..<Int(f.processingFormat.channelCount) {
            for i in 0..<Int(buf.frameLength) { m = max(m, abs(buf.floatChannelData![c][i])) }
        }
        return m
    }
}

final class AudioMixerTests: XCTestCase {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mixer-tests-\(UUID().uuidString)")
    override func setUpWithError() throws { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func clip(_ type: ClipType = .audio, src: String, start: Double = 0, duration: Double, offset: Double = 0, volume: Double? = nil) -> Clip {
        var c = Clip(); c.type = type; c.src = src; c.start = start; c.duration = duration; c.offset = offset; c.volume = volume
        return c
    }

    func project(_ tracks: [[Clip]], muted: Set<Int> = []) -> Project {
        var p = Project()
        p.tracks = tracks.enumerated().map { i, cs in
            var t = Track(name: "L\(i)"); t.clips = cs; if muted.contains(i) { t.muted = true }; return t
        }
        return p
    }

    func mix(_ p: Project) throws -> (URL, Double) {
        let out = tmp.appendingPathComponent("mix-\(UUID().uuidString).caf")
        let d = try AudioMixer.mixdown(project: p, assets: RenderAssets(), to: out)
        return (out, d)
    }

    func sine(_ name: String, sr: Double = 24000, ch: Int = 1, segments: [(Double, Float)] = [(1, 0.2)]) throws -> String {
        let u = tmp.appendingPathComponent(name)
        try AudioFixture.writeSine(u, sampleRate: sr, channels: ch, segments: segments)
        return u.path
    }

    func testFormatAndDuration() throws {
        let a = try sine("a.wav")  // 24 kHz モノ → 48 kHz ステレオ
        let (out, d) = try mix(project([[clip(src: a, start: 0.5, duration: 1)]]))
        XCTAssertEqual(d, 1.5, accuracy: 0.001)
        let f = try AVAudioFile(forReading: out)
        XCTAssertEqual(f.processingFormat.sampleRate, 48000)
        XCTAssertEqual(f.processingFormat.channelCount, 2)
        XCTAssertEqual(Double(f.length) / 48000, 1.5, accuracy: 0.001)
        XCTAssertEqual(try AudioFixture.peak(out, from: 0, to: 0.45), 0, accuracy: 1e-6)  // 開始前は無音
        XCTAssertEqual(try AudioFixture.peak(out, from: 0.6, to: 1.4), 0.2, accuracy: 0.01)  // 振幅は保たれる
    }

    func testMonoAndStereoSourcesAtOtherSampleRates() throws {
        for (sr, ch) in [(44100.0, 2), (16000.0, 1), (48000.0, 1), (48000.0, 2)] {
            let a = try sine("s\(Int(sr))-\(ch).wav", sr: sr, ch: ch)
            let (out, _) = try mix(project([[clip(src: a, duration: 1)]]))
            XCTAssertEqual(try AudioFixture.peak(out, from: 0.1, to: 0.9), 0.2, accuracy: 0.01, "\(sr) Hz \(ch) ch")
        }
    }

    func testOverlappingTonesAddUp() throws {
        let a = try sine("a.wav"), b = try sine("b.wav")
        let (out, _) = try mix(project([[clip(src: a, duration: 1)], [clip(src: b, duration: 1)]]))
        XCTAssertEqual(try AudioFixture.peak(out, from: 0.1, to: 0.9), 0.4, accuracy: 0.02)
    }

    func testMutedTrackIsSilent() throws {
        let a = try sine("a.wav")
        let p = project([[clip(src: a, duration: 1)]], muted: [0])
        let (out, d) = try mix(p)
        XCTAssertEqual(d, 1, accuracy: 0.001)
        XCTAssertEqual(try AudioFixture.peak(out, from: 0, to: 1), 0)
        // 消音レイヤーだけなら「音声なし」(書き出しは音声入力を省く)
        XCTAssertEqual(try AudioMixer.mixdownDetailed(project: p, to: tmp.appendingPathComponent("m2.caf")).sourceCount, 0)
    }

    func testVolumeHalvesAmplitude() throws {
        let a = try sine("a.wav")
        let (full, _) = try mix(project([[clip(src: a, duration: 1)]]))
        let (half, _) = try mix(project([[clip(src: a, duration: 1, volume: 0.5)]]))
        let (zero, _) = try mix(project([[clip(src: a, duration: 1, volume: 0)]]))
        let pf = try AudioFixture.peak(full, from: 0.1, to: 0.9), ph = try AudioFixture.peak(half, from: 0.1, to: 0.9)
        XCTAssertEqual(ph / pf, 0.5, accuracy: 0.02)
        XCTAssertEqual(try AudioFixture.peak(zero, from: 0, to: 1), 0)
    }

    func testOffsetTrimsTheSourceHead() throws {
        // 前半 1 秒は振幅 0.2、後半 1 秒は 0.6 のファイルを offset 1.0 で使うと 0.6 の側だけが鳴る
        let a = try sine("two.wav", segments: [(1, 0.2), (1, 0.6)])
        let (out, d) = try mix(project([[clip(src: a, start: 0.5, duration: 1, offset: 1.0)]]))
        XCTAssertEqual(d, 1.5, accuracy: 0.001)
        XCTAssertEqual(try AudioFixture.peak(out, from: 0, to: 0.45), 0)
        XCTAssertEqual(try AudioFixture.peak(out, from: 0.6, to: 1.4), 0.6, accuracy: 0.02)
        // offset 0 なら前半(0.2)
        let (out0, _) = try mix(project([[clip(src: a, start: 0, duration: 1, offset: 0)]]))
        XCTAssertEqual(try AudioFixture.peak(out0, from: 0.1, to: 0.9), 0.2, accuracy: 0.01)
    }

    func testSumIsClippedToUnity() throws {
        let a = try sine("loud.wav", segments: [(1, 0.8)])
        let (out, _) = try mix(project([[clip(src: a, duration: 1)], [clip(src: a, duration: 1)], [clip(src: a, duration: 1)]]))
        XCTAssertEqual(try AudioFixture.peak(out, from: 0.1, to: 0.9), 1.0, accuracy: 1e-6)
    }

    func testVoiceClipsAreMixedAndMissingFileThrows() throws {
        let a = try sine("v.wav")
        let (out, _) = try mix(project([[clip(.voice, src: a, duration: 1)]]))
        XCTAssertEqual(try AudioFixture.peak(out, from: 0.1, to: 0.9), 0.2, accuracy: 0.01)
        XCTAssertThrowsError(try mix(project([[clip(src: tmp.appendingPathComponent("none.wav").path, duration: 1)]])))
    }

    func testLongProjectProcessedInChunks() throws {
        // 10 秒の塊をまたぐ(25 秒)クリップが途切れず、開始位置もずれない
        let a = try sine("long.wav", sr: 8000, segments: [(25, 0.3)])
        let (out, d) = try mix(project([[clip(src: a, start: 1, duration: 25)]]))
        XCTAssertEqual(d, 26, accuracy: 0.001)
        for t in [1.5, 9.9, 10.05, 19.95, 20.05, 25.9] {
            XCTAssertEqual(try AudioFixture.peak(out, from: t, to: t + 0.05 > 26 ? 26 : t + 0.04), 0.3, accuracy: 0.03, "t=\(t)")
        }
    }
}
