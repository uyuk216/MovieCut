import XCTest
import AVFoundation
@testable import MovieCutCore

/// 現状確認専用プローブ(最終的には削除し、結果だけ docs に残す)
final class MultichannelProbeTests: XCTestCase {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mc-probe-\(UUID().uuidString)")
    override func setUpWithError() throws { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func writeDC(_ url: URL, values: [Float], sampleRate: Double = 48000, seconds: Double = 0.5) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: values.count,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        print("PROBE write \(url.lastPathComponent) fmt ch=\(file.processingFormat.channelCount) layoutTag=\(file.processingFormat.channelLayout?.layoutTag ?? 0) bitmap=\(String(describing: file.processingFormat.channelLayout?.layout))")
        let total = Int(seconds * sampleRate)
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(total))!
        buf.frameLength = AVAudioFrameCount(total)
        for c in 0..<values.count { for i in 0..<total { buf.floatChannelData![c][i] = values[c] } }
        try file.write(from: buf)
    }

    func writeTones(_ url: URL, freqs: [Double], amp: Float = 0.5, sampleRate: Double = 48000, seconds: Double = 1.0) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: freqs.count,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let total = Int(seconds * sampleRate)
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(total))!
        buf.frameLength = AVAudioFrameCount(total)
        for c in 0..<freqs.count { for i in 0..<total { buf.floatChannelData![c][i] = amp * Float(sin(2 * .pi * freqs[c] * Double(i) / sampleRate)) } }
        try file.write(from: buf)
    }

    func readStereo(_ url: URL) throws -> (l: [Float], r: [Float], sr: Double) {
        let f = try AVAudioFile(forReading: url)
        let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
        try f.read(into: buf)
        let n = Int(buf.frameLength)
        return (Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: n)),
                Array(UnsafeBufferPointer(start: buf.floatChannelData![1], count: n)), f.processingFormat.sampleRate)
    }

    func goertzel(_ x: [Float], freq: Double, sr: Double) -> Double {
        let n = x.count; guard n > 0 else { return 0 }
        let w = 2 * Double.pi * freq / sr; let cw = cos(w); let coeff = 2 * cw
        var s0 = 0.0, s1 = 0.0, s2 = 0.0
        for v in x { s0 = Double(v) + coeff * s1 - s2; s2 = s1; s1 = s0 }
        let power = s1 * s1 + s2 * s2 - coeff * s1 * s2
        return 2 * sqrt(max(0, power)) / Double(n)
    }

    func mixOne(src: String, type: ClipType = .audio, duration: Double = 0.5) throws -> URL {
        var c = Clip(); c.type = type; c.src = src; c.start = 0; c.duration = duration
        var p = Project(); var t = Track(name: "L0"); t.clips = [c]; p.tracks = [t]
        let out = tmp.appendingPathComponent("mix-\(UUID().uuidString).caf")
        _ = try AudioMixer.mixdown(project: p, assets: RenderAssets(), to: out)
        return out
    }

    func testProbeDC() throws {
        let cases: [[Float]] = [
            [0.42],
            [0.42, -0.36],
            [0.42, -0.36, 0.30],
            [0.42, -0.36, 0.30, 0.18],
            [0.42, -0.36, 0.30, 0.12, 0.24, -0.24],
            [0.42, -0.36, 0.30, 0.12, 0.24, -0.24, 0.10, -0.10],
        ]
        for values in cases {
            let u = tmp.appendingPathComponent("dc\(values.count).wav")
            try writeDC(u, values: values)
            // 読み戻してレイアウト確認
            let rf = try AVAudioFile(forReading: u)
            print("PROBE readback \(values.count)ch fmt ch=\(rf.processingFormat.channelCount) layoutTag=\(rf.processingFormat.channelLayout?.layoutTag ?? 0)")
            let out = try mixOne(src: u.path)
            let (l, r, _) = try readStereo(out)
            let lm = l.reduce(0, +) / Float(l.count), rm = r.reduce(0, +) / Float(r.count)
            print(String(format: "PROBE DC %dch in=%@ -> L=%.4f R=%.4f", values.count, values.map { String(format: "%.2f", $0) }.joined(separator: ","), lm, rm))
        }
    }

    func testProbeTones51WavResampled() throws {
        let freqs = [200.0, 400, 600, 100, 800, 1000]
        let u = tmp.appendingPathComponent("tones51.wav")
        try writeTones(u, freqs: freqs, sampleRate: 24000)
        let out = try mixOne(src: u.path, duration: 1.0)
        let (l, r, sr) = try readStereo(out)
        for (i, f) in freqs.enumerated() {
            print(String(format: "PROBE TONE51 ch%d %.0fHz amp L=%.4f R=%.4f", i, f, goertzel(l, freq: f, sr: sr), goertzel(r, freq: f, sr: sr)))
        }
    }

    func testProbeAssetVideo51() throws {
        // ffmpeg 製の 5.1ch 動画ファイルを使う(テスト側で事前に tmp へ生成済みなら使う)
        let v = URL(fileURLWithPath: "/tmp/mc-probe51b.mp4")
        guard FileManager.default.fileExists(atPath: v.path) else {
            print("PROBE ASSET skipped (no file)")
            return
        }
        let out = try mixOne(src: v.path, type: .video, duration: 1.0)
        let (l, r, sr) = try readStereo(out)
        for f in [200.0, 400, 600, 100, 800, 1000] {
            print(String(format: "PROBE ASSET51 %.0fHz amp L=%.4f R=%.4f", f, goertzel(l, freq: f, sr: sr), goertzel(r, freq: f, sr: sr)))
        }
    }
}
