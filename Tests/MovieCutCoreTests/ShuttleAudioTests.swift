import XCTest
import AVFoundation
@testable import MovieCutCore

/// 2 倍・4 倍の音(クリップの速度変更の書き出しと、シャトルの再生)。音程を保つ設定(keepPitch)に従う。
final class ShuttleAudioTests: XCTestCase {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("shuttle-audio-tests-\(UUID().uuidString)")
    override func setUpWithError() throws { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func writeTone(_ name: String, f: Double, seconds: Double) throws -> URL {
        let url = tmp.appendingPathComponent(name)
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: fmt.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let n = Int(seconds * 48000)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n))!
        buf.frameLength = AVAudioFrameCount(n)
        for i in 0..<n { let v = Float(0.5 * sin(2 * Double.pi * f * Double(i) / 48000)); buf.floatChannelData![0][i] = v; buf.floatChannelData![1][i] = v }
        try file.write(from: buf)
        return url
    }

    func frequency(_ s: ArraySlice<Float>) -> Double {
        var crossings = 0
        var prev = s.first ?? 0
        for v in s.dropFirst() { if (prev < 0) != (v < 0) { crossings += 1 }; prev = v }
        return Double(crossings) / 2 / (Double(s.count) / 48000)
    }

    func mix(_ p: Project) throws -> (samples: [Float], duration: Double) {
        let out = tmp.appendingPathComponent("mix-\(UUID().uuidString).caf")
        let res = try AudioMixer.mixdownDetailed(project: p, to: out)
        let f = try AVAudioFile(forReading: out)
        let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
        try f.read(into: buf)
        return (Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength))), res.duration)
    }

    func project(_ url: URL, dur: Double, speed: Double?, keepPitch: Bool? = nil) -> Project {
        var a = Clip(); a.id = "a"; a.type = .audio; a.src = url.path; a.start = 0; a.duration = dur; a.srcDuration = 20
        a.speed = speed; a.keepPitch = keepPitch
        var p = Project(); var tr = Track(name: "L1"); tr.clips = [a]; p.tracks = [tr]
        return p
    }

    // MARK: 書き出し(ミックス)で 4 倍

    func testFourTimesKeepsPitchAndQuartersDuration() throws {
        let tone = try writeTone("t440.wav", f: 440, seconds: 8)
        let r = try mix(project(tone, dur: 2, speed: 4))            // 素材 8 秒を 2 秒で
        XCTAssertEqual(r.duration, 2, accuracy: 1e-6)
        XCTAssertEqual(r.samples.count, 96000, "長さはクリップの長さにぴったり")
        let f = frequency(r.samples[9600..<86400])
        XCTAssertEqual(f, 440, accuracy: 440 * 0.04, "音程を保つ: \(f) Hz")
        XCTAssertGreaterThan(r.samples[2000..<6000].map { abs($0) }.max() ?? 0, 0.3, "頭から鳴っている")
        XCTAssertGreaterThan(r.samples[90000..<94000].map { abs($0) }.max() ?? 0, 0.3, "終わりまで鳴っている")
    }

    func testFourTimesWithoutKeepPitchRaisesTwoOctaves() throws {
        let tone = try writeTone("t440b.wav", f: 440, seconds: 8)
        let r = try mix(project(tone, dur: 2, speed: 4, keepPitch: false))
        XCTAssertEqual(r.samples.count, 96000)
        let f = frequency(r.samples[9600..<86400])
        XCTAssertEqual(f, 1760, accuracy: 1760 * 0.03, "音程を保たない: 4 倍高い \(f) Hz")
    }

    // MARK: シャトルの部品(再生と同じ部品を、オフラインで通して確かめる)

    /// tone を rate 倍にして、`seconds` 秒ぶん取り出す(再生が使う `makeRateUnit` を通す)。
    func renderThroughRateUnit(_ url: URL, rate: Double, keepPitch: Bool, seconds: Double) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let fmt = file.processingFormat
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let unit = ShuttleAudio.makeRateUnit(rate: rate, keepPitch: keepPitch)
        engine.attach(player); engine.attach(unit)
        engine.connect(player, to: unit, format: fmt)
        engine.connect(unit, to: engine.mainMixerNode, format: fmt)
        try engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: 4096)
        engine.prepare()
        try engine.start()
        defer { player.stop(); engine.stop() }
        player.scheduleFile(file, at: nil, completionHandler: nil)
        player.play()
        let buf = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096)!
        var out: [Float] = []
        let want = Int(seconds * 48000)
        var stalls = 0
        while out.count < want {
            let st = try engine.renderOffline(AVAudioFrameCount(min(4096, want - out.count)), to: buf)
            if st == .success {
                out.append(contentsOf: UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
                stalls = 0
            } else { stalls += 1; if stalls > 500 { break } }
        }
        return out
    }

    func testRateUnitFourTimesKeepPitchAndVarispeed() throws {
        let tone = try writeTone("t440c.wav", f: 440, seconds: 6)
        let keep = try renderThroughRateUnit(tone, rate: 4, keepPitch: true, seconds: 1)
        XCTAssertEqual(keep.count, 48000)
        XCTAssertEqual(frequency(keep[9600..<43200]), 440, accuracy: 440 * 0.04, "TimePitch: 音程は 1 倍と同じ")
        let vari = try renderThroughRateUnit(tone, rate: 4, keepPitch: false, seconds: 1)
        XCTAssertEqual(frequency(vari[9600..<43200]), 1760, accuracy: 1760 * 0.03, "Varispeed: 4 倍高い")
        let two = try renderThroughRateUnit(tone, rate: 2, keepPitch: true, seconds: 1)
        XCTAssertEqual(frequency(two[9600..<43200]), 440, accuracy: 440 * 0.04)
        // 4 倍で 1 秒ぶん出る = 素材の 4 秒ぶんを使っている(素材は 6 秒なので途切れない)
        XCTAssertGreaterThan(keep[40000..<46000].map { abs($0) }.max() ?? 0, 0.3)
    }

    // MARK: 速さ・音程の決め方

    func testSpeedRangeAndPitchPolicy() {
        XCTAssertFalse(ShuttleAudio.playsAudio(speed: 1), "1 倍は通常の再生")
        XCTAssertTrue(ShuttleAudio.playsAudio(speed: 2))
        XCTAssertTrue(ShuttleAudio.playsAudio(speed: 4))
        XCTAssertFalse(ShuttleAudio.playsAudio(speed: -1), "逆再生は無音")
        XCTAssertFalse(ShuttleAudio.playsAudio(speed: 0))
        XCTAssertFalse(ShuttleAudio.playsAudio(speed: 8))
        var a = Clip(); a.id = "a"; a.type = .audio; a.src = "/x.wav"; a.start = 1; a.duration = 2
        var b = Clip(); b.id = "b"; b.type = .audio; b.src = "/y.wav"; b.start = 5; b.duration = 2; b.keepPitch = false
        var p = Project(); var tr = Track(name: "L1"); tr.clips = [a, b]; p.tracks = [tr]
        XCTAssertTrue(ShuttleAudio.keepsPitch(in: p, at: 1.5), "既定は保つ")
        XCTAssertFalse(ShuttleAudio.keepsPitch(in: p, at: 5.5), "クリップが保たない設定ならシャトルも合わせる")
        XCTAssertTrue(ShuttleAudio.keepsPitch(in: p, at: 4), "音のない所は既定")
    }
}
