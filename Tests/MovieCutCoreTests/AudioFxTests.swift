import XCTest
import AVFoundation
@testable import MovieCutCore

/// 音声エフェクトの信号処理(純粋な DSP)と、ミキサー経由の結果、ファイル形式、編集の計算。
final class AudioFxTests: XCTestCase {
    let sr = 48000.0
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("audiofx-tests-\(UUID().uuidString)")
    override func setUpWithError() throws { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    // MARK: ヘルパー

    func sine(_ f: Double, amp: Float = 0.1, seconds: Double = 1) -> [Float] {
        (0..<Int(seconds * sr)).map { amp * Float(sin(2 * .pi * f * Double($0) / sr)) }
    }
    func rms(_ x: ArraySlice<Float>) -> Double { (x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, x.count))).squareRoot() }
    func dB(_ v: Double) -> Double { 20 * log10(max(v, 1e-12)) }

    func run(_ x: [Float], _ f: (UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>, Int) -> Void) -> (l: [Float], r: [Float]) {
        var l = x, r = x
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in f(lp.baseAddress!, rp.baseAddress!, lp.count) } }
        return (l, r)
    }

    /// 定常状態(後半)の利得(dB)
    func measuredGain(_ eq: AudioFx.EQ, f: Double) -> Double {
        let x = sine(f, seconds: 1)
        let p = EQProcessor(eq, sr: sr)
        let y = run(x) { p.process($0, $1, $2) }
        return dB(rms(y.l[Int(sr / 2)...])) - dB(rms(x[Int(sr / 2)...]))
    }

    // MARK: EQ

    func testEQGainAtTargetFrequencies() {
        // 各帯域 +6 / −6 / +12 dB を、帯域の中心・十分内側の周波数で測る(仕様の ±1 dB)
        for g in [6.0, -6.0, 12.0, -12.0] {
            XCTAssertEqual(measuredGain(AudioFx.EQ(mid: g), f: 1000), g, accuracy: 1.0, "mid \(g)")
            XCTAssertEqual(measuredGain(AudioFx.EQ(low: g), f: 30), g, accuracy: 1.0, "low \(g)")
            XCTAssertEqual(measuredGain(AudioFx.EQ(high: g), f: 16000), g, accuracy: 1.0, "high \(g)")
        }
        // 帯域の外は動かない(低域シェルフは 8 kHz に影響しない、など)
        XCTAssertEqual(measuredGain(AudioFx.EQ(low: 12), f: 8000), 0, accuracy: 0.5)
        XCTAssertEqual(measuredGain(AudioFx.EQ(high: 12), f: 100), 0, accuracy: 0.5)
        XCTAssertEqual(measuredGain(AudioFx.EQ(mid: 12), f: 100), 0, accuracy: 2.5)
        // シェルフの中心周波数ではちょうど半分
        XCTAssertEqual(measuredGain(AudioFx.EQ(low: 12), f: 100), 6, accuracy: 0.3)
        XCTAssertEqual(measuredGain(AudioFx.EQ(high: -12), f: 8000), -6, accuracy: 0.3)
    }

    func testEQMagnitudeMatchesMeasurement() {
        let eq = AudioFx.EQ(low: 5, mid: -7, high: 9)
        for f in [50.0, 100, 300, 1000, 3000, 8000, 15000] {
            let analytic = dB(EQProcessor.magnitude(eq, at: f, sr: sr))
            XCTAssertEqual(measuredGain(eq, f: f), analytic, accuracy: 0.15, "\(f) Hz")
        }
    }

    func testFlatEQIsExactBypass() {
        let x = sine(440)
        let p = EQProcessor(AudioFx.EQ(), sr: sr)
        XCTAssertEqual(run(x) { p.process($0, $1, $2) }.l, x)
    }

    func testEQClampsOutOfRange() {
        XCTAssertEqual(AudioFx.EQ(low: 99).lowDb, 12)
        XCTAssertEqual(AudioFx.EQ(low: -99).lowDb, -12)
        XCTAssertEqual(AudioFx.EQ(low: .nan).lowDb, 0)
    }

    // MARK: コンプレッサー

    func testCompressorReducesPeaksByExpectedRatio() {
        let c = AudioFx.Compressor(threshold: -20, ratio: 4, attack: 1, release: 50, makeup: 0)
        let x = sine(440, amp: 0.8, seconds: 1)           // ピーク −1.94 dBFS
        let p = CompressorProcessor(c, sr: sr)
        let y = run(x) { p.process($0, $1, $2) }
        let outPeak = dB(Double(y.l[Int(sr / 2)...].map { abs($0) }.max()!))
        let inPeak = dB(0.8)
        let expected = -20 + (inPeak + 20) / 4
        XCTAssertEqual(outPeak, expected, accuracy: 1.0)
        XCTAssertLessThan(outPeak, inPeak - 8)             // はっきり下がっている
    }

    func testCompressorLeavesQuietSignalAndMakeupRaisesIt() {
        let x = sine(440, amp: 0.01)                        // −40 dBFS: しきい値(−20)より下
        let p = CompressorProcessor(AudioFx.Compressor(threshold: -20, ratio: 8, attack: 5, release: 50, makeup: 0), sr: sr)
        let y = run(x) { p.process($0, $1, $2) }
        XCTAssertEqual(y.l, x)
        let m = CompressorProcessor(AudioFx.Compressor(threshold: -20, ratio: 8, attack: 5, release: 50, makeup: 6), sr: sr)
        let z = run(x) { m.process($0, $1, $2) }
        XCTAssertEqual(dB(rms(z.l[1000...])) - dB(rms(x[1000...])), 6, accuracy: 0.05)
    }

    func testCompressorNarrowsDynamicRange() {
        // 大きい音と小さい音の差が縮まる
        let loud = sine(440, amp: 0.8, seconds: 1), quiet = sine(440, amp: 0.05, seconds: 1)
        let x = loud + quiet
        let p = CompressorProcessor(AudioFx.Compressor(threshold: -30, ratio: 6, attack: 2, release: 40, makeup: 0), sr: sr)
        let y = run(x) { p.process($0, $1, $2) }
        let before = dB(rms(x[Int(0.5 * sr)..<Int(sr)])) - dB(rms(x[Int(1.5 * sr)...]))
        let after = dB(rms(y.l[Int(0.5 * sr)..<Int(sr)])) - dB(rms(y.l[Int(1.5 * sr)...]))
        XCTAssertLessThan(after, before - 10)
    }

    // MARK: ノーマライズ

    func meterOf(_ x: [Float]) -> LevelMeter {
        let m = LevelMeter()
        x.withUnsafeBufferPointer { m.add($0.baseAddress!, $0.baseAddress!, $0.count) }
        return m
    }

    func testNormalizePeakHitsTargetWithinTenthOfADecibel() {
        let x = sine(1000, amp: 0.2)
        let m = meterOf(x)
        for target in [-1.0, -6.0, -12.0, 0.0] {
            let g = AudioNormalizer.gain(AudioFx.Normalize(targetDb: target, mode: .peak), meter: m)
            XCTAssertEqual(dB(Double(m.peak * g)), target, accuracy: 0.1, "target \(target)")
        }
    }

    func testNormalizeLoudnessReachesTarget() {
        // 1 kHz の正弦波: ステレオ同一信号なら、K 特性込みの値は −0.691 + 10log10(2·g²·amp²/2) 付近。測り直して確かめる
        let x = sine(1000, amp: 0.05)
        let m = meterOf(x)
        let g = AudioNormalizer.gain(AudioFx.Normalize(targetDb: -16, mode: .loudness), meter: m)
        let m2 = meterOf(x.map { $0 * g })
        XCTAssertEqual(m2.loudness, -16, accuracy: 0.1)
        // 大きすぎる目標はピーク −0.1 dBFS で止める
        let hot = meterOf(sine(1000, amp: 0.9))
        let g2 = AudioNormalizer.gain(AudioFx.Normalize(targetDb: -9, mode: .loudness), meter: hot)
        XCTAssertLessThanOrEqual(dB(Double(hot.peak * g2)), -0.09)
    }

    func testNormalizeSilenceIsUnity() {
        let m = meterOf([Float](repeating: 0, count: 4800))
        XCTAssertEqual(AudioNormalizer.gain(AudioFx.Normalize(), meter: m), 1)
    }

    // MARK: パン

    func testPanIsEqualPowerAndCenterIsUnity() {
        let c = AudioPan.gains(0)
        XCTAssertEqual(c.l, 1, accuracy: 1e-6); XCTAssertEqual(c.r, 1, accuracy: 1e-6)
        for p in stride(from: -1.0, through: 1.0, by: 0.125) {
            let g = AudioPan.gains(p)
            XCTAssertEqual(Double(g.l * g.l + g.r * g.r), 2, accuracy: 1e-5, "pan \(p)")
        }
        let l = AudioPan.gains(-1), r = AudioPan.gains(1)
        XCTAssertEqual(l.r, 0, accuracy: 1e-6); XCTAssertEqual(r.l, 0, accuracy: 1e-6)
        XCTAssertEqual(Double(l.l), 2.0.squareRoot(), accuracy: 1e-6)
        // 左右対称
        let a = AudioPan.gains(0.3), b = AudioPan.gains(-0.3)
        XCTAssertEqual(a.l, b.r, accuracy: 1e-6)
        XCTAssertGreaterThan(a.r, a.l)
    }

    // MARK: リバーブ

    func testReverbMixZeroIsBypassAndTailHasEnergy() {
        var x = [Float](repeating: 0, count: Int(sr))
        x[0] = 1
        // mix 0: 原音そのまま
        let dry = ReverbProcessor(AudioFx.Reverb(mix: 0, size: .large), sr: sr)
        XCTAssertEqual(run(x) { dry.process($0, $1, $2) }.l, x)
        XCTAssertFalse(AudioFx.Reverb(mix: 0).isActive)
        // mix 0.5: インパルスのあとに余韻が残る
        for size in AudioFx.ReverbSize.allCases {
            let p = ReverbProcessor(AudioFx.Reverb(mix: 0.5, size: size), sr: sr)
            let y = run(x) { p.process($0, $1, $2) }
            let tail = y.l[Int(0.05 * sr)...].reduce(0.0) { $0 + Double($1) * Double($1) }
            XCTAssertGreaterThan(tail, 1e-6, "\(size)")
            XCTAssertTrue(y.l.allSatisfy { $0.isFinite })
        }
    }

    func testReverbHallRingsLongerThanSmall() {
        var x = [Float](repeating: 0, count: Int(2 * sr))
        x[0] = 1
        func lateEnergy(_ s: AudioFx.ReverbSize) -> Double {
            let p = ReverbProcessor(AudioFx.Reverb(mix: 1, size: s), sr: sr)
            let y = run(x) { p.process($0, $1, $2) }
            return y.l[Int(1.0 * sr)...].reduce(0.0) { $0 + Double($1) * Double($1) }
        }
        XCTAssertGreaterThan(lateEnergy(.hall), lateEnergy(.small) * 10)
    }

    func testChainIsDeterministic() {
        let fx = AudioFx(eq: AudioFx.EQ(low: 4, mid: -3, high: 5), compressor: AudioFx.Compressor(threshold: -24, ratio: 4, attack: 5, release: 80, makeup: 2),
                         reverb: AudioFx.Reverb(mix: 0.3, size: .medium))
        let x = sine(330, amp: 0.5) + sine(1700, amp: 0.2)
        func once() -> [Float] { let c = AudioFxChain(fx, sr: sr); return run(x) { c.process($0, $1, $2) }.l }
        XCTAssertEqual(once(), once())
        // 塊に分けて処理しても、一括と同じ(状態が塊をまたいで続く)
        let c = AudioFxChain(fx, sr: sr)
        var l = x, r = x
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            var pos = 0
            for n in [1000, 4097, 777, 16384] where pos < lp.count {
                let m = min(n, lp.count - pos); c.process(lp.baseAddress! + pos, rp.baseAddress! + pos, m); pos += m
            }
            if pos < lp.count { c.process(lp.baseAddress! + pos, rp.baseAddress! + pos, lp.count - pos) }
        } }
        XCTAssertEqual(l, once())
    }

    // MARK: 音量の包絡

    func testVolumeEnvelopeIsContinuousAndFollowsKeys() throws {
        for ease in [Ease.linear, .easeInOut, .easeIn, .bezier(0.3, 0, 0.7, 1)] {
            let env = try XCTUnwrap(VolumeEnvelope([Keyframe(t: 0.5, v: 0.2, ease: ease), Keyframe(t: 1.5, v: 1.6, ease: ease), Keyframe(t: 2.5, v: 0.5)], sr: sr))
            var prev = env.gain(at: 0)
            var worst: Float = 0
            for i in 1..<Int(3 * sr) {
                let g = env.gain(at: i)
                worst = max(worst, abs(g - prev)); prev = g
            }
            XCTAssertLessThan(worst, 0.001, "\(ease)")    // 1 サンプルで 0.1% 以上は動かない(ジッパーなし)
            XCTAssertEqual(env.gain(at: 0), 0.2, accuracy: 1e-6)          // 最初のキーより前は端の値
            XCTAssertEqual(env.gain(at: Int(1.5 * sr)), 1.6, accuracy: 1e-5)
            XCTAssertEqual(env.gain(at: Int(10 * sr)), 0.5, accuracy: 1e-6)
        }
        // 逆向きに評価しても同じ値
        let env = try XCTUnwrap(VolumeEnvelope([Keyframe(t: 0, v: 0), Keyframe(t: 1, v: 1), Keyframe(t: 2, v: 0)], sr: sr))
        let fwd = (0..<96000).map { env.gain(at: $0) }
        let back = (0..<96000).reversed().map { env.gain(at: $0) }.reversed()
        XCTAssertEqual(fwd, Array(back))
        XCTAssertNil(VolumeEnvelope([], sr: sr))
    }

    // MARK: ミキサー経由

    func writeTone(_ name: String, f: Double, amp: Float, seconds: Double) throws -> String {
        let url = tmp.appendingPathComponent(name)
        try AudioFixture.writeSine(url, sampleRate: 48000, channels: 2, frequency: f, segments: [(seconds, amp)])
        return url.path
    }

    func clip(_ src: String, start: Double = 0, duration: Double, type: ClipType = .audio) -> Clip {
        var c = Clip(); c.type = type; c.src = src; c.start = start; c.duration = duration; c.srcDuration = duration; c.volume = 1
        return c
    }

    func project(_ clips: [Clip]) -> Project {
        var p = Project(); var t = Track(name: "L"); t.clips = clips; p.tracks = [t]; return p
    }

    func mix(_ p: Project, _ name: String = "mix.caf") throws -> (l: [Float], r: [Float]) {
        let url = tmp.appendingPathComponent(name)
        try AudioMixer.mixdown(project: p, assets: RenderAssets(), to: url)
        let f = try AVAudioFile(forReading: url)
        let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
        try f.read(into: buf)
        let n = Int(buf.frameLength)
        return (Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: n)), Array(UnsafeBufferPointer(start: buf.floatChannelData![1], count: n)))
    }

    func testMixdownEQCutAndBoostChangeLevel() throws {
        let src = try writeTone("t1k.wav", f: 1000, amp: 0.2, seconds: 2)
        let base = try mix(project([clip(src, duration: 2)]))
        let baseRms = rms(base.l[Int(0.5 * sr)...])
        for g in [6.0, -6.0] {
            var c = clip(src, duration: 2)
            AudioFxEditing.setEQ(&c, band: .mid, db: g)
            let y = try mix(project([c]), "eq\(g).caf")
            XCTAssertEqual(dB(rms(y.l[Int(0.5 * sr)...])) - dB(baseRms), g, accuracy: 0.5)
        }
        // 効いていないエフェクト(EQ 平ら・リバーブ mix 0)は、まったく同じ出力
        var flat = clip(src, duration: 2)
        flat.audioFx = AudioFx(eq: AudioFx.EQ(low: 0), reverb: AudioFx.Reverb(mix: 0))
        XCTAssertEqual(try mix(project([flat]), "flat.caf").l, base.l)
    }

    func testMixdownCompressedLoudQuiet() throws {
        let url = tmp.appendingPathComponent("lq.wav")
        try AudioFixture.writeSine(url, sampleRate: 48000, channels: 2, frequency: 440, segments: [(1.5, 0.8), (1.5, 0.05)])
        var c = clip(url.path, duration: 3)
        AudioFxEditing.setCompressor(&c, .threshold, -30); AudioFxEditing.setCompressor(&c, .ratio, 6)
        AudioFxEditing.setCompressor(&c, .attack, 2); AudioFxEditing.setCompressor(&c, .release, 40)
        let dry = try mix(project([clip(url.path, duration: 3)]))
        let wet = try mix(project([c]), "c.caf")
        let drySpread = dB(rms(dry.l[Int(0.5 * sr)..<Int(sr)])) - dB(rms(dry.l[Int(2.5 * sr)...]))
        let wetSpread = dB(rms(wet.l[Int(0.5 * sr)..<Int(sr)])) - dB(rms(wet.l[Int(2.5 * sr)...]))
        XCTAssertLessThan(wetSpread, drySpread - 10)
    }

    func testMixdownNormalizeHitsTargetPeak() throws {
        let src = try writeTone("quiet.wav", f: 700, amp: 0.1, seconds: 3)
        for (target, expectation) in [(-1.0, -1.0), (-6.0, -6.0), (-12.0, -12.0)] {
            var c = clip(src, duration: 3)
            AudioFxEditing.normalizePeak(&c, targetDb: target)
            let y = try mix(project([c]), "n\(target).caf")
            let pk = dB(Double(max(y.l.map { abs($0) }.max()!, y.r.map { abs($0) }.max()!)))
            XCTAssertEqual(pk, expectation, accuracy: 0.1, "target \(target)")
        }
        // 速度変更(別の経路)でも、使う範囲を測って合わせる / 範囲の一部だけ使うクリップでも、その範囲で合わせる
        var half = clip(src, duration: 1)
        half.offset = 1
        AudioFxEditing.normalizePeak(&half, targetDb: -3)
        let y = try mix(project([half]), "half.caf")
        XCTAssertEqual(dB(Double(y.l.map { abs($0) }.max()!)), -3, accuracy: 0.1)
    }

    func testMixdownVolumeRampIsSmooth() throws {
        let src = try writeTone("v.wav", f: 440, amp: 0.5, seconds: 4)
        var c = clip(src, duration: 4)
        c.keyframes["volume"] = [Keyframe(t: 1, v: 0), Keyframe(t: 3, v: 1)]
        let y = try mix(project([c]))
        // 区間ごとのピーク: 前半は 0 → 無音、後半は 1 倍の 0.5
        func peak(_ a: Double, _ b: Double) -> Float { y.l[Int(a * sr)..<Int(b * sr)].map { abs($0) }.max()! }
        XCTAssertLessThan(peak(0, 0.99), 1e-4)
        XCTAssertEqual(peak(3.05, 3.95), 0.5, accuracy: 0.01)
        XCTAssertEqual(peak(1.95, 2.05), 0.25, accuracy: 0.02)         // 真ん中で半分
        // 包絡の滑らかさ: 10 ms ごとのピークが単調に増える
        var last: Float = -1
        for k in 0..<190 {
            let t = 1.0 + Double(k) * 0.01
            let p = peak(t, t + 0.01)
            XCTAssertGreaterThanOrEqual(p, last - 0.003); last = p
        }
        // 塊(10 秒)の境目をまたぐ長いクリップでも途切れない
        let long = tmp.appendingPathComponent("long.wav")
        try AudioFixture.writeSine(long, sampleRate: 48000, channels: 2, frequency: 440, segments: [(22, 0.5)])
        var lc = clip(long.path, duration: 22)
        lc.keyframes["volume"] = [Keyframe(t: 0, v: 0.2), Keyframe(t: 22, v: 1.0)]
        let ly = try mix(project([lc]), "long.caf")
        for boundary in [10.0, 20.0] {
            let a = ly.l[Int(boundary * sr) - 2000..<Int(boundary * sr)].map { abs($0) }.max()!
            let b = ly.l[Int(boundary * sr)..<Int(boundary * sr) + 2000].map { abs($0) }.max()!
            XCTAssertEqual(a, b, accuracy: 0.01, "境目 \(boundary)")
        }
    }

    func testMixdownPanMovesEnergyBetweenChannels() throws {
        let src = try writeTone("p.wav", f: 440, amp: 0.3, seconds: 1)
        var left = clip(src, duration: 1); AudioFxEditing.setPan(&left, -1)
        let y = try mix(project([left]))
        XCTAssertLessThan(rms(y.r[1000...]), 1e-6)
        XCTAssertEqual(rms(y.l[1000...]) / (0.3 / 2.0.squareRoot()), 2.0.squareRoot(), accuracy: 0.01)
        var center = clip(src, duration: 1); AudioFxEditing.setPan(&center, 0)
        XCTAssertNil(center.pan)
    }

    func testMixdownReverbAddsTailAndFxOnVoiceClip() throws {
        let src = try writeTone("rv.wav", f: 600, amp: 0.4, seconds: 1)
        var c = clip(src, duration: 1, type: .voice)
        c.audioFx = AudioFx(reverb: AudioFx.Reverb(mix: 0.5, size: .hall))
        let y = try mix(project([c]))
        let dry = try mix(project([clip(src, duration: 1, type: .voice)]), "dry.caf")
        XCTAssertNotEqual(y.l, dry.l)
        XCTAssertTrue(y.l.allSatisfy { $0.isFinite && abs($0) <= 1 })
    }

    func testMixdownIsDeterministicWithAllFx() throws {
        let src = try writeTone("det.wav", f: 500, amp: 0.4, seconds: 2)
        var c = clip(src, duration: 2)
        c.audioFx = AudioFx(eq: AudioFx.EQ(low: 3, mid: -2, high: 4), compressor: AudioFx.Compressor(), reverb: AudioFx.Reverb(mix: 0.2, size: .large),
                            normalize: AudioFx.Normalize(targetDb: -3, mode: .peak))
        c.pan = 0.4; c.fadeIn = 0.2
        c.keyframes["volume"] = [Keyframe(t: 0, v: 0.5), Keyframe(t: 2, v: 1)]
        let a = try mix(project([c]), "d1.caf"), b = try mix(project([c]), "d2.caf")
        XCTAssertEqual(a.l, b.l); XCTAssertEqual(a.r, b.r)
    }

    // MARK: ファイル形式

    func testDefaultsWriteNothing() throws {
        var c = clip("/a.wav", duration: 1)
        var s = String(decoding: try project([c]).encoded(), as: UTF8.self)
        for k in ["audioFx", "pan"] { XCTAssertFalse(s.contains("\"\(k)\""), k) }
        c.audioFx = AudioFx()                              // 空は書かない
        c.pan = nil
        s = String(decoding: try project([c]).encoded(), as: UTF8.self)
        XCTAssertFalse(s.contains("audioFx"))
        c.audioFx = AudioFx(eq: AudioFx.EQ(mid: 3))
        s = String(decoding: try project([c]).encoded(), as: UTF8.self)
        XCTAssertTrue(s.contains("\"mid\""))
        XCTAssertFalse(s.contains("\"low\"")); XCTAssertFalse(s.contains("compressor"))
    }

    func fixtureURL(_ name: String, ext: String = "ymproj") throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
    }

    func testAudioFxFixtureRoundTripsAndKeepsUnknown() throws {
        let p1 = try Project.load(from: fixtureURL("audiofx"))
        let full = try XCTUnwrap(p1.allClips.first { $0.id == "afull" })
        XCTAssertEqual([full.audioFx?.eq?.low, full.audioFx?.eq?.mid, full.audioFx?.eq?.high], [3, -2, 4.5])
        XCTAssertEqual(full.audioFx?.compressor?.thresholdDb, -24)
        XCTAssertEqual(full.audioFx?.compressor?.ratioValue, 4)
        XCTAssertEqual(full.audioFx?.reverb?.sizeOrDefault, .hall)
        XCTAssertEqual(full.audioFx?.normalize?.modeOrDefault, .loudness)
        XCTAssertEqual(full.audioFx?.normalize?.targetDb, -14)
        XCTAssertEqual(full.pan, -0.35)
        XCTAssertEqual(full.keyframes["volume"]?.count, 3)
        XCTAssertEqual(full.audioFx?.extra["futureFx"], .string("keep"))
        XCTAssertEqual(full.audioFx?.eq?.extra["band4"], .number(1))
        let off = try XCTUnwrap(p1.allClips.first { $0.id == "aoff" })
        XCTAssertFalse(off.audioFx!.compressor!.enabled)
        XCTAssertFalse(off.audioFx!.compressor!.isActive)    // 切ってあるものは音に効かない
        XCTAssertTrue(off.audioFx!.reverb!.isActive)         // 空の {} は既定値(ミックス 25%)で効く
        XCTAssertEqual(off.audioFx?.reverb?.mix, 0.25)      // 既定値の読み出し
        let bad = try XCTUnwrap(p1.allClips.first { $0.id == "abad" })
        XCTAssertNil(bad.audioFx)
        XCTAssertEqual(bad.extra["audioFx"], .string("not an object"))
        XCTAssertEqual(bad.extra["pan"], .string("left"))

        let d1 = try p1.encoded()
        let p2 = try Project.decode(from: d1)
        XCTAssertEqual(p1, p2)
        XCTAssertEqual(try p2.encoded(), d1)
        let s = String(decoding: d1, as: UTF8.self)
        for k in ["futureFx", "band4", "not an object", "\"left\""] { XCTAssertTrue(s.contains(k), k) }
    }

    func testOldFixturesCarryNoAudioFxKeys() throws {
        for n in ["rich", "electron-made", "speed", "transitions"] {
            let s = String(decoding: try Project.load(from: fixtureURL(n)).encoded(), as: UTF8.self)
            for k in ["audioFx", "\"pan\""] { XCTAssertFalse(s.contains(k), "\(n) に \(k) が増えた") }
        }
    }

    // MARK: 編集

    func testEditingFunctionsAreNoOpAware() {
        var c = clip("/a.wav", duration: 4)
        XCTAssertFalse(AudioFxEditing.setEQ(&c, band: .low, db: 0))               // 変化なし
        XCTAssertTrue(AudioFxEditing.setEQ(&c, band: .low, db: 3))
        XCTAssertFalse(AudioFxEditing.setEQ(&c, band: .low, db: 3))
        XCTAssertTrue(AudioFxEditing.setEQ(&c, band: .low, db: 0))
        XCTAssertNil(c.audioFx)                                                    // 全部 0 に戻すと外れる
        XCTAssertTrue(AudioFxEditing.setCompressorEnabled(&c, true))
        XCTAssertFalse(AudioFxEditing.setCompressorEnabled(&c, true))
        XCTAssertTrue(AudioFxEditing.setCompressor(&c, .ratio, 99))
        XCTAssertEqual(c.audioFx?.compressor?.ratioValue, 20)                      // 範囲に収める
        XCTAssertTrue(AudioFxEditing.setCompressorEnabled(&c, false))
        XCTAssertFalse(c.hasAudioFx)
        XCTAssertFalse(AudioFxEditing.setCompressorEnabled(&c, false))
        XCTAssertTrue(AudioFxEditing.setPan(&c, 2)); XCTAssertEqual(c.pan, 1)
        XCTAssertTrue(AudioFxEditing.setPan(&c, 0)); XCTAssertNil(c.pan)
        XCTAssertFalse(AudioFxEditing.setPan(&c, 0))
        XCTAssertTrue(AudioFxEditing.setNormalizeMode(&c, .loudness)); XCTAssertEqual(c.audioFx?.normalize?.targetDb, -16)
        XCTAssertFalse(AudioFxEditing.setNormalizeMode(&c, .loudness))
        XCTAssertTrue(AudioFxEditing.setNormalizeTarget(&c, -5)); XCTAssertEqual(c.audioFx?.normalize?.targetDb, -9)   // ラウドネスの範囲に収める
        // 対応しないクリップ
        var img = Clip(); img.type = .image
        XCTAssertFalse(AudioFxEditing.setPan(&img, 0.5)); XCTAssertFalse(AudioFxEditing.normalizePeak(&img))
    }

    func testVolumeStepAndPresetsAndClear() {
        var c = clip("/a.wav", duration: 4)
        XCTAssertTrue(AudioFxEditing.stepVolume(&c, db: 3)); XCTAssertEqual(c.volume!, 1.413, accuracy: 0.001)
        XCTAssertTrue(AudioFxEditing.stepVolume(&c, db: -3)); XCTAssertEqual(c.volume!, 1.0, accuracy: 0.002)
        c.volume = 2
        XCTAssertFalse(AudioFxEditing.stepVolume(&c, db: 3))                       // 上限
        c.volume = 0
        XCTAssertFalse(AudioFxEditing.stepVolume(&c, db: 3))
        c.volume = 1
        c.keyframes["volume"] = [Keyframe(t: 0, v: 0.5), Keyframe(t: 1, v: 1)]
        XCTAssertTrue(AudioFxEditing.stepVolume(&c, db: 6))
        XCTAssertEqual(c.keyframes["volume"]!.map(\.v)[0], 0.998, accuracy: 0.002)
        XCTAssertEqual(c.volume, 1)                                                // キーがあるときは設定値を触らない
        AudioFxEditing.setPan(&c, 0.5)
        XCTAssertTrue(AudioFxEditing.clearAll(&c))
        XCTAssertNil(c.audioFx); XCTAssertNil(c.pan)
        XCTAssertFalse(AudioFxEditing.clearAll(&c))
        XCTAssertNotNil(c.keyframes["volume"])                                     // 音量は外さない
    }

    func testVolumeIsAnimatableKey() {
        var c = clip("/a.wav", duration: 4)
        XCTAssertEqual(Animation.keys(for: c), ["volume"])
        XCTAssertEqual(Animation.keys(for: clip("/v.mp4", duration: 1, type: .video)).last, "volume")
        XCTAssertTrue(Animation.keys(for: { var i = Clip(); i.type = .image; return i }()).allSatisfy { $0 != "volume" })
        c.volume = 0.8
        XCTAssertTrue(KeyframeEditing.toggle(&c, key: "volume", at: 1, tolerance: 0.01))
        XCTAssertEqual(c.keyframes["volume"]?.first?.v, 0.8)
        KeyframeEditing.setValue(&c, key: "volume", 5, at: 1, tolerance: 0.01)
        XCTAssertEqual(c.keyframes["volume"]?.first?.v, 2)                         // 範囲 0〜2 に収める
        XCTAssertTrue(KeyframeEditing.toggle(&c, key: "volume", at: 1, tolerance: 0.01))   // 最後の 1 つを消すと設定値に戻る
        XCTAssertNil(c.keyframes["volume"]); XCTAssertEqual(c.volume, 2)
    }
}
