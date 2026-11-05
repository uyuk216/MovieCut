import XCTest
import AVFoundation
@testable import MovieCutCore

/// ノイズ除去(強): スペクトルゲート。合成した「正弦波 + ノイズ」で SNR の改善を測る。
final class SpectralDenoiseTests: XCTestCase {
    let sr = 48000.0
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("spectral-denoise-tests-\(UUID().uuidString)")
    override func setUpWithError() throws { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    /// 決まった白色ノイズ(線形合同法。一様分布 ±amp)
    func noise(_ n: Int, amp: Float, seed: UInt64 = 12345) -> [Float] {
        var s = seed
        return (0..<n).map { _ in
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return amp * (Float(Int64(bitPattern: s) >> 11) / Float(1 << 52))
        }
    }

    /// 頭 `lead` 秒はノイズだけ、その後はトーン + ノイズ。clean はトーンだけの正解。
    func signal(seconds: Double = 2, lead: Double = 0.7, f: Double = 1000, toneAmp: Float = 0.3, noiseAmp: Float = 0.1) -> (noisy: [Float], clean: [Float]) {
        let n = Int(seconds * sr), start = Int(lead * sr)
        let nz = noise(n, amp: noiseAmp)
        var clean = [Float](repeating: 0, count: n), noisy = nz
        for i in start..<n {
            let v = toneAmp * Float(sin(2 * .pi * f * Double(i) / sr))
            clean[i] = v; noisy[i] += v
        }
        return (noisy, clean)
    }

    func snr(_ x: [Float], clean: [Float], from: Int, to: Int) -> Double {
        var sig = 0.0, err = 0.0
        for i in from..<to { sig += Double(clean[i] * clean[i]); let d = Double(x[i] - clean[i]); err += d * d }
        return 10 * log10(sig / max(err, 1e-20))
    }

    // MARK: 往復(マスクが全部 1 なら入力と一致する = 遅れも位置ずれもない)

    func testIdentityWhenNoiseProfileIsZero() {
        let x = noise(30000, amp: 0.5, seed: 9)
        let zero = SpectralDenoise.Profile(power: [Float](repeating: 0, count: SpectralDenoise.fftSize / 2))
        let src = SpectralDenoise.ArraySource(x, x)
        let d = SpectralDenoiseSource(inner: src, profile: zero, strength: 0.7)
        var l = [Float](repeating: 0, count: x.count), r = l
        let got = l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in d.read(left: lp.baseAddress!, right: rp.baseAddress!, frames: x.count) } }
        XCTAssertEqual(got, x.count, "入力と同じ長さ")
        var worst: Float = 0
        for i in 0..<x.count { worst = max(worst, abs(l[i] - x[i])) }
        XCTAssertLessThan(worst, 2e-4, "STFT → 逆 STFT が元の波形に戻る(最大誤差 \(worst))")
    }

    // MARK: SNR

    func testSNRImprovesByAtLeastSixDecibels() {
        let s = signal()
        let from = Int(1.0 * sr), to = Int(1.9 * sr)
        let before = snr(s.noisy, clean: s.clean, from: from, to: to)
        for strength in [0.5, 0.8, 1.0] {
            let out = SpectralDenoise.process(left: s.noisy, right: s.noisy, sampleRate: sr, strength: strength).left
            XCTAssertEqual(out.count, s.noisy.count)
            let after = snr(out, clean: s.clean, from: from, to: to)
            print("[snr] 強さ \(strength): \(String(format: "%.1f", before)) dB → \(String(format: "%.1f", after)) dB(改善 \(String(format: "%.1f", after - before)) dB)")
            XCTAssertGreaterThanOrEqual(after - before, 6, "強さ \(strength): SNR \(before) → \(after) dB")
        }
    }

    func testStrongerThanSimpleDenoiseOnToneInNoise() throws {
        let s = signal()
        // 簡易版(静かな所を下げるだけ)は、トーンの最中のノイズを消せない
        var fx = AudioFx(); fx.denoise = 0.8
        let chain = AudioFxChain(fx, sr: sr)
        var l = s.noisy, r = s.noisy
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in chain.process(lp.baseAddress!, rp.baseAddress!, lp.count) } }
        let from = Int(1.0 * sr), to = Int(1.9 * sr)
        let simple = snr(l, clean: s.clean, from: from, to: to)
        let strong = snr(SpectralDenoise.process(left: s.noisy, right: s.noisy, sampleRate: sr, strength: 0.8).left, clean: s.clean, from: from, to: to)
        print("[snr] 簡易 \(String(format: "%.1f", simple)) dB / 強 \(String(format: "%.1f", strong)) dB")
        XCTAssertGreaterThan(strong, simple + 6)
    }

    func testToneLevelIsKept() {
        let s = signal()
        let out = SpectralDenoise.process(left: s.noisy, right: s.noisy, sampleRate: sr, strength: 0.8).left
        func rms(_ a: ArraySlice<Float>) -> Double { (a.reduce(0) { $0 + Double($1 * $1) } / Double(a.count)).squareRoot() }
        let from = Int(1.0 * sr), to = Int(1.9 * sr)
        let want = 0.3 / 2.0.squareRoot()
        XCTAssertEqual(rms(out[from..<to]), want, accuracy: want * 0.1, "トーンの大きさは(約 −1 dB 以内で)保たれる")
        // ノイズだけの頭は、ほぼ消える
        XCTAssertLessThan(rms(out[Int(0.1 * sr)..<Int(0.6 * sr)]), rms(s.noisy[Int(0.1 * sr)..<Int(0.6 * sr)]) * 0.15)
    }

    // MARK: 決定性・読み方

    func testDeterministicAndIndependentOfReadBlockSize() {
        let s = signal(seconds: 1.5)
        let a = SpectralDenoise.process(left: s.noisy, right: s.noisy, sampleRate: sr, strength: 0.6)
        let b = SpectralDenoise.process(left: s.noisy, right: s.noisy, sampleRate: sr, strength: 0.6)
        XCTAssertEqual(a.left, b.left, "同じ入力は同じ出力")
        // 読む塊の大きさを変えても同じ
        let make = { () -> PCMSource? in SpectralDenoise.ArraySource(s.noisy, s.noisy) }
        let prof = SpectralDenoise.estimateProfile(open: make, sampleRate: sr)!
        for block in [1, 777, 5000] {
            let d = SpectralDenoiseSource(inner: make()!, profile: prof, strength: 0.6)
            var out: [Float] = [], tmpR = [Float](repeating: 0, count: block), tmpL = tmpR
            while true {
                let got = tmpL.withUnsafeMutableBufferPointer { lp in tmpR.withUnsafeMutableBufferPointer { rp in d.read(left: lp.baseAddress!, right: rp.baseAddress!, frames: block) } }
                if got <= 0 { break }
                out.append(contentsOf: tmpL[0..<got])
                if block == 1 && out.count >= 6000 { break }
            }
            let n = min(out.count, a.left.count)
            XCTAssertEqual(Array(out[0..<n]), Array(a.left[0..<n]), "塊 \(block)")
            if block != 1 { XCTAssertEqual(out.count, s.noisy.count) }
        }
    }

    func testProfileComesFromTheQuietestHalfSecond() {
        // 前半 1 秒は大きなトーン、後ろ 0.6 秒はごく小さいノイズだけ → 型は小さいノイズのパワー
        let n1 = Int(1.0 * sr), n2 = Int(0.6 * sr)
        var x = (0..<n1).map { 0.5 * Float(sin(2 * .pi * 700 * Double($0) / sr)) }
        x += noise(n2, amp: 0.001)
        let prof = SpectralDenoise.estimateProfile(open: { SpectralDenoise.ArraySource(x, x) }, sampleRate: sr)
        XCTAssertNotNil(prof)
        let total = prof!.power.reduce(0, +)
        // 参照: 0.001 の一様ノイズ(分散 ≈ 3.3e-7)の 1 フレームの全 bin パワー ≈ 窓(総和 w² = 768)× 分散 × 4(zrip の 2 倍)× N/2 … と同じ桁
        let tone = SpectralDenoise.estimateProfile(open: { SpectralDenoise.ArraySource(Array(x[0..<n1]), Array(x[0..<n1])) }, sampleRate: sr)!.power.reduce(0, +)
        XCTAssertLessThan(total, tone / 1000, "静かな区間から作っている")
    }

    func testTooShortInputPassesThrough() {
        let x = noise(1500, amp: 0.3)
        XCTAssertNil(SpectralDenoise.estimateProfile(open: { SpectralDenoise.ArraySource(x, x) }, sampleRate: sr))
        let out = SpectralDenoise.process(left: x, right: x, sampleRate: sr, strength: 0.8)
        XCTAssertEqual(out.left, x)
    }

    func testStereoChannelsAreProcessedIndependently() {
        let s = signal(seconds: 1.5)
        let silent = [Float](repeating: 0, count: s.noisy.count)
        let out = SpectralDenoise.process(left: s.noisy, right: silent, sampleRate: sr, strength: 0.8)
        XCTAssertEqual(out.right.map { abs($0) }.max() ?? 1, 0, accuracy: 1e-7, "無音の側は無音のまま")
        XCTAssertGreaterThan(out.left.map { abs($0) }.max() ?? 0, 0.2)
    }

    // MARK: 速さ

    func testProcessingSpeed() {
        let s = signal(seconds: 10, lead: 1)
        let t0 = Date()
        _ = SpectralDenoise.process(left: s.noisy, right: s.noisy, sampleRate: sr, strength: 0.8)
        let sec = Date().timeIntervalSince(t0)
        print("[perf] スペクトルゲート 10 秒のステレオを \(String(format: "%.2f", sec)) 秒(\(String(format: "%.0f", 10 / sec)) 倍速)")
        XCTAssertLessThan(sec, 10, "実時間より速い")
    }

    // MARK: ミキサー経由(書き出し・再生と同じ道)

    func writeWav(_ name: String, _ x: [Float]) throws -> URL {
        let url = tmp.appendingPathComponent(name)
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: 2, interleaved: false)!
        let f = try AVAudioFile(forWriting: url, settings: fmt.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(x.count))!
        buf.frameLength = AVAudioFrameCount(x.count)
        for i in 0..<x.count { buf.floatChannelData![0][i] = x[i]; buf.floatChannelData![1][i] = x[i] }
        try f.write(from: buf)
        return url
    }

    func mixLeft(_ p: Project) throws -> [Float] {
        let out = tmp.appendingPathComponent("mix-\(UUID().uuidString).caf")
        _ = try AudioMixer.mixdownDetailed(project: p, to: out)
        let f = try AVAudioFile(forReading: out)
        let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
        try f.read(into: buf)
        return Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
    }

    func project(_ url: URL, dur: Double, fx: AudioFx?) -> Project {
        var a = Clip(); a.id = "a"; a.type = .audio; a.src = url.path; a.start = 0; a.duration = dur; a.srcDuration = dur
        a.audioFx = fx
        var p = Project(); var tr = Track(name: "L1"); tr.clips = [a]; p.tracks = [tr]
        return p
    }

    func testMixdownAppliesSpectralDenoiseWithoutShiftingTheSound() throws {
        let s = signal()
        let url = try writeWav("noisy.wav", s.noisy)
        var spec = AudioFx(); spec.denoise = 0.8; spec.denoiseSpectral = true
        var simple = AudioFx(); simple.denoise = 0.8
        let plain = try mixLeft(project(url, dur: 2, fx: nil))
        let strong = try mixLeft(project(url, dur: 2, fx: spec))
        let weak = try mixLeft(project(url, dur: 2, fx: simple))
        XCTAssertEqual(strong.count, plain.count, "長さは変わらない")
        let from = Int(1.0 * sr), to = Int(1.9 * sr)
        let b = snr(plain, clean: s.clean, from: from, to: to)
        let a = snr(strong, clean: s.clean, from: from, to: to)
        let w = snr(weak, clean: s.clean, from: from, to: to)
        print("[snr] ミキサー経由: 処理なし \(String(format: "%.1f", b)) / 簡易 \(String(format: "%.1f", w)) / 強 \(String(format: "%.1f", a)) dB")
        XCTAssertGreaterThanOrEqual(a - b, 6)
        XCTAssertGreaterThan(a, w + 3)
        // 同じ設定で 2 回ミックスしても同じ
        let again = try mixLeft(project(url, dur: 2, fx: spec))
        XCTAssertEqual(strong, again)
    }

    // MARK: ファイル形式

    func testSpectralFlagIsOptionalAndOnlyWrittenWhenUsed() throws {
        var c = Clip(); c.type = .audio; c.src = "/x.wav"; c.duration = 1
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        XCTAssertTrue(AudioFxEditing.setDenoise(&c, 0.5))
        var text = String(decoding: try enc.encode(c), as: UTF8.self)
        XCTAssertFalse(text.contains("denoiseSpectral"), "簡易のときは書かない: \(text)")
        XCTAssertTrue(AudioFxEditing.setDenoiseSpectral(&c, true))
        text = String(decoding: try enc.encode(c), as: UTF8.self)
        XCTAssertTrue(text.contains("\"denoiseSpectral\":true"))
        XCTAssertTrue(c.audioFx!.spectralDenoiseOn)
        XCTAssertNotEqual(c.audioFx!.cacheToken, AudioFx(denoise: 0.5).cacheToken, "再生用ミックスの鍵が変わる")
        let back = try JSONDecoder().decode(Clip.self, from: Data(text.utf8))
        XCTAssertEqual(back.audioFx, c.audioFx)
        XCTAssertEqual(String(decoding: try enc.encode(back), as: UTF8.self), text, "往復でバイト一致")
        // 切るとキーごと消える
        XCTAssertTrue(AudioFxEditing.setDenoiseSpectral(&c, false))
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(c), as: UTF8.self).contains("denoiseSpectral"))
        XCTAssertFalse(AudioFxEditing.setDenoiseSpectral(&c, false), "変わらなければ false")
        // 強さを 0 に戻したらスペクトルの印も外れる
        _ = AudioFxEditing.setDenoiseSpectral(&c, true)
        XCTAssertTrue(AudioFxEditing.setDenoise(&c, 0))
        XCTAssertNil(c.audioFx)
    }

    func testTurningSpectralOnWithoutStrengthAddsDefaultStrength() {
        var c = Clip(); c.type = .audio; c.src = "/x.wav"; c.duration = 1
        XCTAssertTrue(AudioFxEditing.setDenoiseSpectral(&c, true))
        XCTAssertEqual(c.audioFx?.denoiseStrength, AudioFxEditing.defaultDenoise)
        XCTAssertTrue(c.audioFx!.spectralDenoiseOn)
    }
}
