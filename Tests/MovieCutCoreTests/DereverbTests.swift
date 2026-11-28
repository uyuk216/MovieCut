import XCTest
import AVFoundation
@testable import MovieCutCore

/// 反響除去: 合成残響(トーンバースト × 指数減衰のインパルス応答)で、尾のエネルギーの減りを測る。
final class DereverbTests: XCTestCase {
    let sr = 48000.0
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("dereverb-tests-\(UUID().uuidString)")
    override func setUpWithError() throws { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    let burstPeriod = 0.6, burstLen = 0.08, seconds = 3.0

    /// 決まった疑似乱数 [-1, 1)
    func rnd(_ s: inout UInt64) -> Float {
        s = s &* 6364136223846793005 &+ 1442695040888963407
        return Float(Int64(bitPattern: s) >> 11) / Float(1 << 52)
    }

    /// トーンバースト列(乾いた音)。
    func dry(f: Double = 800, amp: Float = 0.5) -> [Float] {
        let n = Int(seconds * sr)
        var x = [Float](repeating: 0, count: n)
        var t = 0.1
        while t + burstLen < seconds {
            let a = Int(t * sr), len = Int(burstLen * sr)
            for i in 0..<len {
                let env = Float(0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(len)))
                x[a + i] = amp * env * Float(sin(2 * Double.pi * f * Double(i) / sr))
            }
            t += burstPeriod
        }
        return x
    }

    /// 疎な指数減衰インパルス応答(T60 秒で −60 dB)。直接音(タップ 0)+ 遅れた反射。
    func reverberate(_ x: [Float], t60: Double = 0.5, seed: UInt64 = 7, taps: Int = 400) -> [Float] {
        var s = seed
        var ir: [(Int, Float)] = [(0, 1)]
        for _ in 0..<taps {
            let pos = 400 + Int(Double(abs(rnd(&s))) * t60 * 1.2 * sr)   // 約 8 ms 以降
            let amp = Float(pow(10, -3 * Double(pos) / (t60 * sr))) * 0.25 * rnd(&s)
            ir.append((pos, amp))
        }
        var y = x
        for (d, g) in ir where d > 0 {
            for i in 0..<(x.count - d) { y[i + d] += g * x[i] }
        }
        return y
    }

    func energy(_ x: [Float], _ a: Int, _ b: Int) -> Double {
        var e = 0.0
        for i in max(0, a)..<min(x.count, b) { e += Double(x[i] * x[i]) }
        return e
    }

    /// 各バースト終了 80 ms 後〜次のバースト 30 ms 前の「尾」と、バースト中の「直接音」のエネルギー。
    func tailAndDirect(_ x: [Float]) -> (tail: Double, direct: Double) {
        var tail = 0.0, direct = 0.0
        var t = 0.1
        while t + burstPeriod < seconds {
            direct += energy(x, Int(t * sr), Int((t + burstLen) * sr))
            tail += energy(x, Int((t + burstLen + 0.08) * sr), Int((t + burstPeriod - 0.03) * sr))
            t += burstPeriod
        }
        return (tail, direct)
    }

    func db(_ a: Double, _ b: Double) -> Double { 10 * log10(max(a, 1e-20) / max(b, 1e-20)) }

    // MARK: 尾が減る

    func testTailEnergyDropsOnSyntheticReverb() {
        let wet = reverberate(dry())
        let before = tailAndDirect(wet)
        for s in [0.5, 1.0] {
            let out = Dereverb.process(left: wet, right: wet, sampleRate: sr, strength: s).left
            let after = tailAndDirect(out)
            let tailDrop = db(before.tail, after.tail), directDrop = db(before.direct, after.direct)
            print("[dereverb] 強さ \(s): 尾 \(String(format: "%.1f", tailDrop)) dB 減 / 直接音 \(String(format: "%.1f", directDrop)) dB 減")
            XCTAssertGreaterThanOrEqual(tailDrop, s >= 1 ? 9 : 5, "尾のエネルギーが有意に減る")
            XCTAssertLessThanOrEqual(directDrop, 4, "直接音は削りすぎない")
        }
        // 強いほどよく減る
        let weak = tailAndDirect(Dereverb.process(left: wet, right: wet, sampleRate: sr, strength: 0.2).left).tail
        let strong = tailAndDirect(Dereverb.process(left: wet, right: wet, sampleRate: sr, strength: 0.9).left).tail
        XCTAssertLessThan(strong, weak)
    }

    // MARK: バイパス・無音・ピーク

    func testZeroStrengthIsBitExactBypass() {
        let wet = reverberate(dry())
        let out = Dereverb.process(left: wet, right: wet.reversed(), sampleRate: sr, strength: 0)
        XCTAssertEqual(out.left, wet)
        XCTAssertEqual(out.right, Array(wet.reversed()))
        let src = SpectralDenoise.ArraySource(wet, wet)
        XCTAssertTrue(Dereverb.makeSource(inner: src, strength: 0, sampleRate: sr) === src, "強さ 0 は処理を挟まない")
    }

    func testSilenceStaysSilentAndLengthKept() {
        let z = [Float](repeating: 0, count: 30000)
        let out = Dereverb.process(left: z, right: z, sampleRate: sr, strength: 1)
        XCTAssertEqual(out.left.count, z.count)
        XCTAssertEqual(out.left.max(), 0); XCTAssertEqual(out.right.min(), 0)
    }

    func testDoesNotClipOrAmplify() {
        let wet = reverberate(dry(amp: 0.9))
        let peakIn = wet.map { abs($0) }.max()!
        let out = Dereverb.process(left: wet, right: wet, sampleRate: sr, strength: 1).left
        XCTAssertLessThanOrEqual(out.map { abs($0) }.max()!, peakIn * 1.05, "入力のピークを超えない")
        XCTAssertTrue(out.allSatisfy { $0.isFinite })
    }

    func testDeterministic() {
        let wet = reverberate(dry())
        XCTAssertEqual(Dereverb.process(left: wet, right: wet, sampleRate: sr, strength: 0.7).left,
                       Dereverb.process(left: wet, right: wet, sampleRate: sr, strength: 0.7).left)
    }

    // MARK: ステレオの定位

    func testStereoImagePreserved() {
        let wet = reverberate(dry())
        let l = wet, r = wet.map { $0 * 0.4 }   // 右は左の 0.4 倍(定位が左寄り)
        let out = Dereverb.process(left: l, right: r, sampleRate: sr, strength: 0.8)
        // 左右ゲイン共有なので、左右の比と相関は保たれる
        var dot = 0.0, el = 0.0, er = 0.0
        for i in 0..<l.count { dot += Double(out.left[i] * out.right[i]); el += Double(out.left[i] * out.left[i]); er += Double(out.right[i] * out.right[i]) }
        XCTAssertGreaterThan(dot / (el * er).squareRoot(), 0.999, "左右の相関が保たれる")
        XCTAssertEqual((er / el).squareRoot(), 0.4, accuracy: 0.01, "左右のレベル比が保たれる")
        // 左だけ音がある入力でも、右は無音のまま
        let z = [Float](repeating: 0, count: l.count)
        let one = Dereverb.process(left: l, right: z, sampleRate: sr, strength: 0.8)
        XCTAssertEqual(one.right.map { abs($0) }.max()!, 0, accuracy: 1e-7)
    }

    // MARK: 保存・復元

    func testSaveRestoreRoundTrip() throws {
        var c = Clip(); c.type = .audio; c.src = "/x.wav"; c.duration = 1
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        let base = String(decoding: try enc.encode(c), as: UTF8.self)
        XCTAssertFalse(base.contains("dereverb"))
        XCTAssertTrue(AudioFxEditing.setDereverb(&c, 0.456))
        XCTAssertEqual(c.audioFx?.dereverb, 0.46)
        XCTAssertTrue(c.hasAudioFx)
        XCTAssertNotEqual(c.audioFx!.cacheToken, AudioFx().cacheToken, "再生用ミックスの鍵に入る")
        let text = String(decoding: try enc.encode(c), as: UTF8.self)
        XCTAssertTrue(text.contains("\"dereverb\":0.46"), text)
        let back = try JSONDecoder().decode(Clip.self, from: Data(text.utf8))
        XCTAssertEqual(back.audioFx, c.audioFx)
        XCTAssertEqual(String(decoding: try enc.encode(back), as: UTF8.self), text, "往復でバイト一致")
        XCTAssertFalse(AudioFxEditing.setDereverb(&c, 0.46), "変わらなければ false")
        XCTAssertTrue(AudioFxEditing.setDereverb(&c, 0))
        XCTAssertNil(c.audioFx, "0 に戻したら項目ごと消える")
        XCTAssertEqual(String(decoding: try enc.encode(c), as: UTF8.self), base)
        // 範囲外・不正値は収める
        var fx = AudioFx(); fx.dereverb = 5; XCTAssertEqual(fx.dereverbStrength, 1)
        fx.dereverb = .nan; XCTAssertEqual(fx.dereverbStrength, 0); XCTAssertTrue(fx.isEmpty)
    }

    func testUnreadableValueIsKeptInExtra() throws {
        let json = #"{"dereverb":"strong","eq":{"low":3}}"#
        let fx = try JSONDecoder().decode(AudioFx.self, from: Data(json.utf8))
        XCTAssertEqual(fx.dereverbStrength, 0)
        let out = String(decoding: try JSONEncoder().encode(fx), as: UTF8.self)
        XCTAssertTrue(out.contains("\"dereverb\":\"strong\""), out)
    }

    // MARK: ミキサー経由(再生・書き出しと同じ道)

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

    func project(_ url: URL, fx: AudioFx?) -> Project {
        var a = Clip(); a.id = "a"; a.type = .audio; a.src = url.path; a.start = 0; a.duration = seconds; a.srcDuration = seconds
        a.audioFx = fx
        var p = Project(); var tr = Track(name: "L1"); tr.clips = [a]; p.tracks = [tr]
        return p
    }

    func testMixdownAppliesDereverbWithoutShiftingTheSound() throws {
        let wet = reverberate(dry())
        let url = try writeWav("wet.wav", wet)
        let plain = try mixLeft(project(url, fx: nil))
        let off = try mixLeft(project(url, fx: AudioFx(dereverb: 0)))
        XCTAssertEqual(off, plain, "強さ 0 は書き出しもバイパスと一致")
        var fx = AudioFx(); fx.dereverb = 0.9
        let out = try mixLeft(project(url, fx: fx))
        XCTAssertEqual(out.count, plain.count, "長さは変わらない")
        let b = tailAndDirect(plain), a = tailAndDirect(out)
        let drop = db(b.tail, a.tail)
        print("[dereverb] ミキサー経由: 尾 \(String(format: "%.1f", drop)) dB 減")
        XCTAssertGreaterThanOrEqual(drop, 8)
        // 位置ずれなし: 最初のバーストの立ち上がりが同じ位置
        let first = { (x: [Float]) in x.firstIndex { abs($0) > 0.1 }! }
        XCTAssertEqual(first(out), first(plain), accuracy: 600)
        XCTAssertEqual(out, try mixLeft(project(url, fx: fx)), "同じ設定なら同じ出力")
    }

    func testMixdownWithDenoiseAndDereverbBothApply() throws {
        let wet = reverberate(dry())
        let url = try writeWav("wet2.wav", wet)
        var fx = AudioFx(); fx.denoise = 0.5; fx.denoiseSpectral = true; fx.dereverb = 0.9
        var onlyDn = AudioFx(); onlyDn.denoise = 0.5; onlyDn.denoiseSpectral = true
        let both = try mixLeft(project(url, fx: fx))
        let dn = try mixLeft(project(url, fx: onlyDn))
        XCTAssertGreaterThan(db(tailAndDirect(dn).tail, tailAndDirect(both).tail), 5, "併用でも反響除去が効く")
    }
}
