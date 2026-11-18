import XCTest
import AVFoundation
@testable import MovieCutCore

/// 拡張エフェクト(W3-06/#65)の信号処理・保存形式・編集と、ノイズ除去(#66)のミックス経由の確認。
final class AudioFxExtendedTests: XCTestCase {
    let sr = 48000.0
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("audiofx-ext-tests-\(UUID().uuidString)")
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

    /// 周波数 f の成分のパワー(DFT 1 ビン)。
    func power(_ x: [Float], at f: Double) -> Double {
        var re = 0.0, im = 0.0
        for (i, v) in x.enumerated() {
            let ph = 2 * Double.pi * f * Double(i) / sr
            re += Double(v) * cos(ph); im -= Double(v) * sin(ph)
        }
        return re * re + im * im
    }

    /// 全部入りの拡張チェーン(無音→無音などの確認用)。
    func allOnExtended() -> AudioFx.Extended {
        AudioFx.Extended(
            lowPass: AudioFx.Filter(freq: 15000), highPass: AudioFx.Filter(freq: 30),
            bandPass: nil, notch: AudioFx.Filter(freq: 3000),
            equalizer: AudioFx.ParametricEQ(g1000: 3),
            distortion: AudioFx.Distortion(), tube: AudioFx.Tube(),
            chorus: AudioFx.Chorus(), flanger: AudioFx.Flanger(), phaser: AudioFx.Phaser(),
            tremolo: AudioFx.Tremolo(), vibrato: AudioFx.Vibrato(), wah: AudioFx.Wah(),
            echo: AudioFx.Echo(), lowQuality: AudioFx.LowQuality(), robot: AudioFx.Robot())
    }

    // MARK: 無音とバイパス(従来経路との一致)

    func testSilenceStaysSilenceThroughEverything() {
        let zeros = [Float](repeating: 0, count: Int(sr))
        let chain = ExtendedChain(allOnExtended(), sr: sr)
        let y = run(zeros) { chain.process($0, $1, $2) }
        XCTAssertTrue(y.l.allSatisfy { $0 == 0 })
        XCTAssertTrue(y.r.allSatisfy { $0 == 0 })
    }

    func testEmptyAndDisabledExtendedAreExactBypass() {
        let x = sine(440, amp: 0.3) + sine(1200, amp: 0.1)
        let empty = ExtendedChain(AudioFx.Extended(), sr: sr)
        XCTAssertEqual(run(x) { empty.process($0, $1, $2) }.l, x)
        // 無効化しただけの拡張は、チェーン自体が作られず従来と完全一致
        let off = AudioFx(extended: AudioFx.Extended(distortion: AudioFx.Distortion(enabled: false), chorus: AudioFx.Chorus(enabled: false)))
        XCTAssertFalse(off.isActive)
        XCTAssertFalse(off.hasChain)
        let plain = AudioFx()
        let a = AudioFxChain(plain, sr: sr), b = AudioFxChain(off, sr: sr)
        let ya = run(x) { a.process($0, $1, $2) }, yb = run(x) { b.process($0, $1, $2) }
        XCTAssertEqual(ya.l, x)
        XCTAssertEqual(yb.l, ya.l)
    }

    func testExtendedChainIsDeterministic() {
        let x = sine(330, amp: 0.4, seconds: 2)
        let a = ExtendedChain(allOnExtended(), sr: sr)
        let b = ExtendedChain(allOnExtended(), sr: sr)
        XCTAssertEqual(run(x) { a.process($0, $1, $2) }.l, run(x) { b.process($0, $1, $2) }.l)
    }

    // MARK: フィルタ

    func measuredGain(kind: AudioFx.FilterKind, filter: AudioFx.Filter, f: Double) -> Double {
        let x = sine(f, seconds: 1)
        let p = FilterProcessor(kind: kind, filter: filter, sr: sr)
        let y = run(x) { p.process($0, $1, $2) }
        return dB(rms(y.l[Int(sr / 2)...])) - dB(rms(x[Int(sr / 2)...]))
    }

    func testLowPassAndHighPass() {
        let lp = AudioFx.Filter(freq: 1000)
        XCTAssertEqual(measuredGain(kind: .lowPass, filter: lp, f: 100), 0, accuracy: 0.5)
        XCTAssertLessThan(measuredGain(kind: .lowPass, filter: lp, f: 12000), -20)
        let hp = AudioFx.Filter(freq: 1000)
        XCTAssertEqual(measuredGain(kind: .highPass, filter: hp, f: 12000), 0, accuracy: 0.5)
        XCTAssertLessThan(measuredGain(kind: .highPass, filter: hp, f: 100), -20)
    }

    func testBandPassAndNotch() {
        let bp = AudioFx.Filter(freq: 1000, q: 1)
        XCTAssertEqual(FilterProcessor.magnitude(kind: .bandPass, filter: bp, at: 1000, sr: sr), 1, accuracy: 0.05)
        XCTAssertLessThan(dB(FilterProcessor.magnitude(kind: .bandPass, filter: bp, at: 100, sr: sr)), -8)
        XCTAssertLessThan(dB(FilterProcessor.magnitude(kind: .bandPass, filter: bp, at: 10000, sr: sr)), -8)
        XCTAssertEqual(measuredGain(kind: .bandPass, filter: bp, f: 1000), 0, accuracy: 0.7)
        let notch = AudioFx.Filter(freq: 1000, q: 8)
        XCTAssertLessThan(measuredGain(kind: .notch, filter: notch, f: 1000), -25)
        XCTAssertEqual(measuredGain(kind: .notch, filter: notch, f: 100), 0, accuracy: 0.7)
    }

    func testParametricEQBoostAndCut() {
        let eq = AudioFx.ParametricEQ(g1000: 6)
        let x = sine(1000, seconds: 1)
        let p = ParametricEQProcessor(eq, sr: sr)
        let y = run(x) { p.process($0, $1, $2) }
        XCTAssertEqual(dB(rms(y.l[Int(sr / 2)...])) - dB(rms(x[Int(sr / 2)...])), 6, accuracy: 1.0)
        XCTAssertEqual(dB(ParametricEQProcessor.magnitude(eq, at: 1000, sr: sr)), 6, accuracy: 0.2)
        let flat = ParametricEQProcessor(AudioFx.ParametricEQ(), sr: sr)
        XCTAssertEqual(run(x) { flat.process($0, $1, $2) }.l, x)
    }

    // MARK: 歪み

    func testDistortionFlattensPeaksAndStaysBounded() {
        let x = sine(440, amp: 0.9, seconds: 1)
        let p = DistortionProcessor(AudioFx.Distortion(drive: 24, mix: 1), sr: sr)
        let y = run(x) { p.process($0, $1, $2) }.l
        XCTAssertTrue(y.allSatisfy { abs($0) <= 1.02 })
        let crestIn = Double(x.map { abs($0) }.max()!) / rms(x[...])
        let crestOut = Double(y.map { abs($0) }.max()!) / rms(y[...])
        XCTAssertLessThan(crestOut, crestIn - 0.15, "波形の頭が潰れてクレストが下がる")
        // 倍音が出る: 3 倍音(1320 Hz)の成分が原音より相対的に増える
        let ratioIn = power(x, at: 1320) / power(x, at: 440)
        let ratioOut = power(y, at: 1320) / power(y, at: 440)
        XCTAssertGreaterThan(ratioOut, ratioIn * 20)
        let bypass = DistortionProcessor(AudioFx.Distortion(drive: 24, mix: 0), sr: sr)
        XCTAssertEqual(run(x) { bypass.process($0, $1, $2) }.l, x)
    }

    func testTubeIsAsymmetricAndBounded() {
        let p = TubeProcessor(AudioFx.Tube(drive: 12, mix: 1), sr: sr)
        let pos = run([Float](repeating: 0.4, count: Int(sr))) { p.process($0, $1, $2) }.l.last!
        let q = TubeProcessor(AudioFx.Tube(drive: 12, mix: 1), sr: sr)
        let neg = run([Float](repeating: -0.4, count: Int(sr))) { q.process($0, $1, $2) }.l.last!
        XCTAssertNotEqual(Double(pos), -Double(neg), accuracy: 0.02, "正負で潰れ方が違う(偶数倍音)")
        XCTAssertLessThanOrEqual(abs(pos), 1.0)
        XCTAssertLessThanOrEqual(abs(neg), 1.0)
        let z = TubeProcessor(AudioFx.Tube(drive: 12, mix: 1), sr: sr)
        XCTAssertTrue(run([Float](repeating: 0, count: 4800)) { z.process($0, $1, $2) }.l.allSatisfy { $0 == 0 })
    }

    // MARK: モジュレーション

    func testChorusDelaysACopyAndBeats() {
        var impulse = [Float](repeating: 0, count: Int(sr / 2)); impulse[0] = 1
        let p = ModulatedDelayProcessor(baseSec: 0.018, depthSec: 0.007, rateHz: 1, feedback: 0, mix: 0.5, wetOnly: false, sr: sr)
        let y = run(impulse) { p.process($0, $1, $2) }.l
        let delayed = y[Int(0.008 * sr)..<Int(0.030 * sr)].map { abs($0) }.max()!
        XCTAssertGreaterThan(delayed, 0.2, "遅れた複製が 8〜30 ms に現れる")
        // 持続音ではうなりが出る(短い窓の RMS が揺れる)
        let x = sine(440, amp: 0.4, seconds: 2)
        let c = ModulatedDelayProcessor(baseSec: 0.018, depthSec: 0.007, rateHz: 1, feedback: 0, mix: 0.5, wetOnly: false, sr: sr)
        let w = run(x) { c.process($0, $1, $2) }.l
        var levels: [Double] = []
        for k in 0..<40 { levels.append(rms(w[(k * 2400)..<((k + 1) * 2400)])) }
        XCTAssertGreaterThan(levels.max()! / max(levels.min()!, 1e-9), 1.3)
    }

    func testFlangerRepeatsWithFeedback() {
        var impulse = [Float](repeating: 0, count: Int(sr / 2)); impulse[0] = 1
        let p = ModulatedDelayProcessor(baseSec: 0.0025, depthSec: 0.0022, rateHz: 0.4, feedback: 0.7, mix: 0.5, wetOnly: false, sr: sr)
        let y = run(impulse) { p.process($0, $1, $2) }.l
        let later = y[Int(0.010 * sr)..<Int(0.025 * sr)].map { abs($0) }.max()!
        XCTAssertGreaterThan(later, 0.02, "フィードバックで繰り返しが続く")
    }

    func testPhaserMovesNotches() {
        let x = sine(1000, amp: 0.5, seconds: 2)
        let p = PhaserProcessor(AudioFx.Phaser(rate: 2, depth: 1, mix: 0.5), sr: sr)
        let y = run(x) { p.process($0, $1, $2) }.l
        var levels: [Double] = []
        for k in 0..<20 { levels.append(rms(y[(k * 4800)..<((k + 1) * 4800)])) }
        XCTAssertGreaterThan(levels.max()! / max(levels.min()!, 1e-9), 1.6, "ノッチが動いてレベルが揺れる")
    }

    func testTremoloModulatesDepthFully() {
        let x = sine(440, amp: 0.5, seconds: 2)
        let p = TremoloProcessor(AudioFx.Tremolo(rate: 5, depth: 1), sr: sr)
        let y = run(x) { p.process($0, $1, $2) }.l
        var levels: [Double] = []
        for k in 0..<80 { levels.append(rms(y[(k * 1200)..<((k + 1) * 1200)])) }
        XCTAssertLessThan(levels.min()!, levels.max()! * 0.3, "一番静かな所はほぼ無音まで落ちる")
    }

    func testVibratoVariesPeriod() {
        let x = sine(440, amp: 0.5, seconds: 2)
        let p = ModulatedDelayProcessor(baseSec: 0.012, depthSec: 0.010, rateHz: 5, feedback: 0, mix: 1, wetOnly: true, sr: sr)
        let y = run(x) { p.process($0, $1, $2) }.l
        XCTAssertNotEqual(y, x)
        XCTAssertEqual(rms(y[Int(sr)...]) / rms(x[Int(sr)...]), 1, accuracy: 0.1, "音量はほぼそのまま")
        // 立ち上がりゼロクロスの間隔(周期)が揺れる
        var crossings: [Int] = []
        for i in 1..<y.count where y[i - 1] < 0 && y[i] >= 0 { crossings.append(i) }
        let intervals = zip(crossings.dropFirst(), crossings).map { $0.0 - $0.1 }
        XCTAssertGreaterThan(Double(intervals.max()!) / Double(intervals.min()!), 1.15)
    }

    // MARK: ワウ

    func testWahManualPositionMovesBoost() {
        func gainAt(_ f: Double, position: Double) -> Double {
            let x = sine(f, amp: 0.2, seconds: 1)
            let p = WahProcessor(AudioFx.Wah(auto: false, position: position), sr: sr)
            let y = run(x) { p.process($0, $1, $2) }
            return dB(rms(y.l[Int(sr / 2)...])) - dB(rms(x[Int(sr / 2)...]))
        }
        XCTAssertGreaterThan(gainAt(400, position: 0) - gainAt(400, position: 1), 3, "閉じ側は低い音を押し上げる")
        XCTAssertGreaterThan(gainAt(2500, position: 1) - gainAt(2500, position: 0), 3, "開き側は高い音を押し上げる")
    }

    func testAutoWahFollowsEnvelope() {
        let x = sine(2500, amp: 0.8, seconds: 1)
        let auto = WahProcessor(AudioFx.Wah(auto: true, sensitivity: 1), sr: sr)
        let ya = run(x) { auto.process($0, $1, $2) }
        let manual = WahProcessor(AudioFx.Wah(auto: false, position: 0), sr: sr)
        let ym = run(x) { manual.process($0, $1, $2) }
        XCTAssertGreaterThan(dB(rms(ya.l[Int(sr / 2)...])) - dB(rms(ym.l[Int(sr / 2)...])), 2, "大きい音でワウが開く")
        // 静かな音では開かない
        let quiet = sine(2500, amp: 0.01, seconds: 1)
        let auto2 = WahProcessor(AudioFx.Wah(auto: true, sensitivity: 1), sr: sr)
        let yq = run(quiet) { auto2.process($0, $1, $2) }
        XCTAssertEqual(dB(rms(yq.l[Int(sr / 2)...])) - dB(rms(quiet[Int(sr / 2)...])), 0, accuracy: 2.5)
    }

    // MARK: エコー

    func testEchoRepeatsDecay() {
        var impulse = [Float](repeating: 0, count: Int(sr)); impulse[0] = 1
        let p = EchoProcessor(AudioFx.Echo(time: 0.1, feedback: 0.6, mix: 0.5), sr: sr)
        let y = run(impulse) { p.process($0, $1, $2) }.l
        func peak(_ a: Double, _ b: Double) -> Float { y[Int(a * sr)..<Int(b * sr)].map { abs($0) }.max()! }
        let r1 = peak(0.09, 0.11), r2 = peak(0.19, 0.21), r3 = peak(0.29, 0.31)
        XCTAssertGreaterThan(r1, 0.2)
        XCTAssertLessThan(r2, r1)
        XCTAssertLessThan(r3, r2)
    }

    func testEchoDarkensRepeatsComparedToDelay() {
        // 8 kHz の短いバーストを繰り返させると、エコーの 2 回目はローパスで暗くなる
        var burst = [Float](repeating: 0, count: Int(sr))
        for i in 0..<Int(0.01 * sr) { burst[i] = 0.8 * Float(sin(2 * .pi * 8000 * Double(i) / sr)) }
        let e = EchoProcessor(AudioFx.Echo(time: 0.05, feedback: 0.7, mix: 0.5), sr: sr)
        let ye = run(burst) { e.process($0, $1, $2) }.l
        let d = DelayProcessor(AudioFx.Delay(time: 0.05, feedback: 0.7, mix: 0.5), sr: sr)
        let yd = run(burst) { d.process($0, $1, $2) }.l
        let secondE = rms(ye[Int(0.10 * sr)..<Int(0.11 * sr)])
        let secondD = rms(yd[Int(0.10 * sr)..<Int(0.11 * sr)])
        XCTAssertLessThan(secondE, secondD * 0.6, "エコーの繰り返しは高域が落ちる")
    }

    // MARK: 低音質化 / ロボット化

    func testLowQualityQuantizesAndHolds() {
        let ramp = (0..<4800).map { Float($0) / 4800 * 0.9 }
        let q = LowQualityProcessor(AudioFx.LowQuality(bits: 4, downsample: 1), sr: sr)
        let y = run(ramp) { q.process($0, $1, $2) }.l
        let step = pow(2.0, 1 - 4.0)
        for v in y { XCTAssertEqual(Double(v) / step, (Double(v) / step).rounded(), accuracy: 0.01, "量子化の段に乗る") }
        let h = LowQualityProcessor(AudioFx.LowQuality(bits: 16, downsample: 4), sr: sr)
        let z = run(ramp) { h.process($0, $1, $2) }.l
        XCTAssertEqual(z[1], z[0]); XCTAssertEqual(z[2], z[0]); XCTAssertEqual(z[3], z[0])
        XCTAssertEqual(z[5], z[4]); XCTAssertEqual(z[6], z[4])
        XCTAssertNotEqual(z[4], z[0])
    }

    func testRobotMovesEnergyToSidebands() {
        let x = sine(440, amp: 0.6, seconds: 1)
        let p = RobotProcessor(AudioFx.Robot(frequency: 50, mix: 1), sr: sr)
        let y = run(x) { p.process($0, $1, $2) }.l
        XCTAssertGreaterThan(power(y, at: 490), power(y, at: 440) * 10, "440 は消え 490(側帯波)に移る")
        XCTAssertGreaterThan(power(y, at: 390), power(y, at: 440) * 10)
        let bypass = RobotProcessor(AudioFx.Robot(frequency: 50, mix: 0), sr: sr)
        XCTAssertEqual(run(x) { bypass.process($0, $1, $2) }.l, x)
    }

    // MARK: 保存形式

    func testExtendedRoundTripsThroughJSON() throws {
        let fx = AudioFx(extended: AudioFx.Extended(
            lowPass: AudioFx.Filter(freq: 9000, q: 1.2), notch: AudioFx.Filter(freq: 3000),
            equalizer: AudioFx.ParametricEQ(g250: -3, g4000: 5),
            distortion: AudioFx.Distortion(drive: 20, mix: 0.6), tube: AudioFx.Tube(),
            chorus: AudioFx.Chorus(rate: 2), flanger: AudioFx.Flanger(feedback: 0.3),
            phaser: AudioFx.Phaser(), tremolo: AudioFx.Tremolo(depth: 0.8), vibrato: AudioFx.Vibrato(),
            wah: AudioFx.Wah(auto: true, sensitivity: 0.7), echo: AudioFx.Echo(time: 0.5),
            lowQuality: AudioFx.LowQuality(bits: 6, downsample: 8), robot: AudioFx.Robot(frequency: 80)))
        let data = try JSONEncoder().encode(fx)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"extended\""))
        XCTAssertEqual(try JSONDecoder().decode(AudioFx.self, from: data), fx)
    }

    func testEmptyExtendedWritesNothing() throws {
        let plain = try JSONEncoder().encode(AudioFx())
        let withEmpty = try JSONEncoder().encode(AudioFx(extended: AudioFx.Extended()))
        XCTAssertEqual(plain, withEmpty, "空の拡張は従来とバイト一致")
        XCTAssertFalse(String(decoding: withEmpty, as: UTF8.self).contains("extended"))
    }

    func testUnknownKeysInsideExtendedAreKept() throws {
        let src = #"{"extended":{"chorus":{"rate":2.0,"futureKey":7},"brandNew":{"a":1}}}"#
        let fx = try JSONDecoder().decode(AudioFx.self, from: Data(src.utf8))
        XCTAssertEqual(fx.extended?.chorus?.rateHz, 2)
        let out = String(decoding: try JSONEncoder().encode(fx), as: UTF8.self)
        XCTAssertTrue(out.contains("futureKey"), "知らないキーは書き戻す: \(out)")
        XCTAssertTrue(out.contains("brandNew"), "知らない項目は書き戻す: \(out)")
    }

    func testClipWithExtendedRoundTrips() throws {
        var c = Clip(); c.type = .audio; c.src = "/tmp/a.wav"; c.duration = 2
        c.audioFx = AudioFx(extended: AudioFx.Extended(flanger: AudioFx.Flanger()))
        let data = try JSONEncoder().encode(c)
        let back = try JSONDecoder().decode(Clip.self, from: data)
        XCTAssertEqual(back.audioFx, c.audioFx)
        XCTAssertEqual(back.audioFx?.extended?.flanger?.feedbackValue, 0.5)
    }

    // MARK: 編集

    func audioClip() -> Clip { var c = Clip(); c.type = .audio; c.src = "/tmp/a.wav"; c.duration = 2; return c }

    func testExtendedEditingNoOpsClampsAndClears() {
        var c = audioClip()
        XCTAssertFalse(AudioFxEditing.setChorusEnabled(&c, false))
        XCTAssertNil(c.audioFx)
        XCTAssertTrue(AudioFxEditing.setChorusEnabled(&c, true))
        XCTAssertEqual(c.audioFx?.extended?.chorus?.isActive, true)
        XCTAssertFalse(AudioFxEditing.setChorusEnabled(&c, true), "同じ状態は変化なし")
        XCTAssertTrue(AudioFxEditing.setChorus(&c, .rate, 99))
        XCTAssertEqual(c.audioFx?.extended?.chorus?.rateHz, 10, "範囲に収める")
        XCTAssertFalse(AudioFxEditing.setChorus(&c, .rate, 99), "収めた結果が同じなら変化なし")
        XCTAssertTrue(AudioFxEditing.setFilter(&c, kind: .lowPass, .freq, 99999))
        XCTAssertEqual(c.audioFx?.extended?.lowPass?.freqOr(0), 20000)
        XCTAssertTrue(AudioFxEditing.setParametricEQ(&c, band: .b1000, db: 30))
        XCTAssertEqual(c.audioFx?.extended?.equalizer?.gain(2), 12)
        XCTAssertTrue(AudioFxEditing.setParametricEQ(&c, band: .b1000, db: 0))
        XCTAssertNil(c.audioFx?.extended?.equalizer, "全バンド 0 で項目ごと消える")
        XCTAssertTrue(AudioFxEditing.setLowQuality(&c, .bits, 1))
        XCTAssertEqual(c.audioFx?.extended?.lowQuality?.bitsValue, 2)
        XCTAssertTrue(AudioFxEditing.clearExtended(&c))
        XCTAssertNil(c.audioFx, "拡張だけだったので audioFx ごと消える")
        XCTAssertFalse(AudioFxEditing.clearExtended(&c))
        // 画像クリップは対象外
        var img = Clip(); img.type = .image
        XCTAssertFalse(AudioFxEditing.setChorusEnabled(&img, true))
        XCTAssertNil(img.audioFx)
    }

    // MARK: ミキサー経由

    func writeTone(_ name: String, f: Double, amp: Float, seconds: Double) throws -> String {
        let url = tmp.appendingPathComponent(name)
        try AudioFixture.writeSine(url, sampleRate: 48000, channels: 2, frequency: f, segments: [(seconds, amp)])
        return url.path
    }

    func clip(_ src: String, duration: Double) -> Clip {
        var c = Clip(); c.type = .audio; c.src = src; c.start = 0; c.duration = duration; c.srcDuration = duration; c.volume = 1
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

    func testMixdownExtendedChangesSoundButNotLength() throws {
        let src = try writeTone("fx.wav", f: 440, amp: 0.3, seconds: 2)
        let dry = try mix(project([clip(src, duration: 2)]))
        var c = clip(src, duration: 2)
        c.audioFx = AudioFx(extended: AudioFx.Extended(distortion: AudioFx.Distortion(), flanger: AudioFx.Flanger()))
        let wet = try mix(project([c]), "wet.caf")
        XCTAssertEqual(wet.l.count, dry.l.count)
        XCTAssertNotEqual(wet.l, dry.l)
        XCTAssertTrue(wet.l.allSatisfy { $0.isFinite && abs($0) <= 1 })
    }

    func testMixdownDisabledExtendedIsByteIdentical() throws {
        let src = try writeTone("plain.wav", f: 440, amp: 0.3, seconds: 2)
        let dry = try mix(project([clip(src, duration: 2)]))
        var c = clip(src, duration: 2)
        c.audioFx = AudioFx(extended: AudioFx.Extended(
            lowPass: AudioFx.Filter(enabled: false),
            distortion: AudioFx.Distortion(enabled: false), chorus: AudioFx.Chorus(enabled: false)))
        let out = try mix(project([c]), "off.caf")
        XCTAssertEqual(out.l, dry.l, "無効な拡張だけなら従来とバイト一致")
        XCTAssertEqual(out.r, dry.r)
    }

    // MARK: ノイズ除去(#66)— ミックス経由で床が下がる

    /// 決定的な疑似ノイズ(線形合同法)の WAV を書く。
    func writeNoise(_ name: String, amp: Float, seconds: Double) throws -> String {
        let url = tmp.appendingPathComponent(name)
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: 2, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: fmt.settings)
        let n = Int(seconds * sr)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n))!
        buf.frameLength = AVAudioFrameCount(n)
        var seed: UInt64 = 0x12345678
        func next() -> Float {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: seed) >> 40) / Float(1 << 23) * amp
        }
        for ch in 0..<2 {
            let p = buf.floatChannelData![ch]
            seed = 0x12345678 &+ UInt64(ch) &* 99991
            for i in 0..<n { p[i] = next() }
        }
        try file.write(from: buf)
        return url.path
    }

    func testMixdownSimpleDenoiseLowersNoiseFloor() throws {
        let src = try writeNoise("noise.wav", amp: 0.03, seconds: 2)
        let dry = try mix(project([clip(src, duration: 2)]))
        var c = clip(src, duration: 2)
        _ = AudioFxEditing.setDenoise(&c, 1)
        let wet = try mix(project([c]), "dn.caf")
        let dryLevel = dB(rms(dry.l[Int(0.5 * sr)...]))
        let wetLevel = dB(rms(wet.l[Int(0.5 * sr)...]))
        XCTAssertLessThan(wetLevel, dryLevel - 6, "静かなノイズの床が下がる: \(dryLevel) → \(wetLevel)")
    }
}
