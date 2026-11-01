import XCTest
@testable import MovieCutCore

/// ノイズ除去(AudioFx.denoise → DenoiseProcessor)。合成した雑音・正弦波だけで確かめる(決定的な乱数)。
final class DenoiseTests: XCTestCase {
    let sr = 48_000.0

    /// 決まった種の一様乱数(RMS = a / √3)。
    func noise(seconds: Double, rms: Double, seed: UInt64) -> [Float] {
        var s = seed
        let a = rms * 3.0.squareRoot()
        return (0..<Int(seconds * sr)).map { _ in
            s = s &* 6364136223846793005 &+ 1442695040888963407
            let u = Double(s >> 11) / Double(1 << 53)
            return Float((u * 2 - 1) * a)
        }
    }

    func tone(seconds: Double, f: Double, amp: Float) -> [Float] {
        (0..<Int(seconds * sr)).map { amp * Float(sin(2 * Double.pi * f * Double($0) / sr)) }
    }

    func rms(_ x: ArraySlice<Float>) -> Double {
        (x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, x.count))).squareRoot()
    }

    /// ステレオで処理(左右は同じ入力)。
    func run(_ x: [Float], _ fx: AudioFx) -> [Float] {
        var l = x, r = x
        let chain = AudioFxChain(fx, sr: sr)
        l.withUnsafeMutableBufferPointer { lp in
            r.withUnsafeMutableBufferPointer { rp in
                // 10 秒ずつ渡す(実際のミキサーと同じく塊をまたいで状態が続く)
                let chunk = Int(sr) * 10
                var i = 0
                while i < lp.count {
                    let n = min(chunk, lp.count - i)
                    chain.process(lp.baseAddress! + i, rp.baseAddress! + i, n)
                    i += n
                }
            }
        }
        return l
    }

    func db(_ ratio: Double) -> Double { 20 * log10(ratio) }

    /// 雑音だけ(RMS 0.02 ≒ −34 dBFS)の 3 秒。最後の 1 秒で測る(立ち上がりを避ける)。
    func testNoiseFloorDropsByAtLeast6dBAtDefaultStrength() {
        let x = noise(seconds: 3, rms: 0.02, seed: 7)
        let y = run(x, AudioFx(denoise: AudioFxEditing.defaultDenoise))
        let tail = Int(2 * sr)..<Int(3 * sr)
        let drop = db(rms(x[tail]) / rms(y[tail]))
        print("DENOISE_DB noise_floor_drop=\(String(format: "%.2f", drop)) strength=0.5")
        XCTAssertGreaterThanOrEqual(drop, 6, "雑音の床が \(drop) dB しか下がらない")
        XCTAssertLessThan(drop, 20, "下げすぎ(\(drop) dB)")
    }

    /// 正弦波(1 kHz・振幅 0.5 ≒ −9 dBFS)は、しきい値より上なので 1.5 dB 以内で残る。
    func testToneIsPreservedWithinOnePointFiveDb() {
        let x = tone(seconds: 3, f: 1000, amp: 0.5)
        let y = run(x, AudioFx(denoise: AudioFxEditing.defaultDenoise))
        let tail = Int(2 * sr)..<Int(3 * sr)
        print("DENOISE_DB tone_only_change=\(String(format: "%.3f", db(rms(y[tail]) / rms(x[tail])))) strength=0.5")
        XCTAssertLessThan(abs(db(rms(y[tail]) / rms(x[tail]))), 1.5)
    }

    /// 雑音に正弦波が重なっているとき、正弦波の高さは 1.5 dB 以内で残る(雑音だけは下がる)。
    func testToneOverNoiseKeepsToneAndCutsNoiseBetweenTones() {
        let t = tone(seconds: 3, f: 1000, amp: 0.5)
        let n = noise(seconds: 3, rms: 0.02, seed: 99)
        let x = zip(t, n).map { $0 + $1 }
        let y = run(x, AudioFx(denoise: AudioFxEditing.defaultDenoise))
        let tail = Int(2 * sr)..<Int(3 * sr)
        print("DENOISE_DB tone_over_noise_change=\(String(format: "%.3f", db(rms(y[tail]) / rms(x[tail])))) strength=0.5")
        XCTAssertLessThan(abs(db(rms(y[tail]) / rms(x[tail]))), 1.5)
    }

    /// 強いほど下がる(単調)。0.2 < 0.5 < 1.0 の順に雑音が小さくなる。
    func testStrengthIsMonotonic() {
        let x = noise(seconds: 3, rms: 0.02, seed: 3)
        let tail = Int(2 * sr)..<Int(3 * sr)
        var last = rms(x[tail])
        for s in [0.2, 0.5, 1.0] {
            let out = rms(run(x, AudioFx(denoise: s))[tail])
            XCTAssertLessThan(out, last, "強さ \(s) で下がらない")
            last = out
        }
    }

    func testSameInputGivesSameOutput() {
        let x = noise(seconds: 1, rms: 0.02, seed: 5)
        XCTAssertEqual(run(x, AudioFx(denoise: 0.5)), run(x, AudioFx(denoise: 0.5)))
    }

    func testZeroStrengthIsBypassAndNotActive() {
        let x = noise(seconds: 1, rms: 0.02, seed: 1)
        let fx = AudioFx(denoise: 0)
        XCTAssertFalse(fx.isActive)
        XCTAssertFalse(fx.hasChain)
        XCTAssertTrue(fx.isEmpty)
        XCTAssertEqual(run(x, fx), x)
        XCTAssertEqual(AudioFx(denoise: 0.5).cacheToken.contains("dn=0.5"), true)
    }

    // MARK: 編集・ファイル

    func clip() -> Clip { var c = Clip(); c.type = .audio; c.src = "a.wav"; c.start = 0; c.duration = 1; c.srcDuration = 1; return c }

    func testEditingSetsClampsAndClearsToNil() {
        var c = clip()
        XCTAssertTrue(AudioFxEditing.setDenoise(&c, 0.5))
        XCTAssertEqual(c.audioFx?.denoise, 0.5)
        XCTAssertFalse(AudioFxEditing.setDenoise(&c, 0.5), "同じ値は変化なし")
        XCTAssertTrue(AudioFxEditing.setDenoise(&c, 7))
        XCTAssertEqual(c.audioFx?.denoise, 1)
        XCTAssertTrue(AudioFxEditing.setDenoise(&c, 0))
        XCTAssertNil(c.audioFx, "0 に戻すと音声エフェクトごと消える")
    }

    func testDenoiseOnlyIsWrittenWhenNonZeroAndRoundTrips() throws {
        var c = clip()
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(c), as: UTF8.self).contains("denoise"))
        AudioFxEditing.setDenoise(&c, 0.35)
        let data = try JSONEncoder().encode(c)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"denoise\":0.35"), text)
        let back = try JSONDecoder().decode(Clip.self, from: data)
        XCTAssertEqual(back.audioFx?.denoise, 0.35)
    }

    func testBadTypedDenoiseIsKeptAsExtra() throws {
        let json = #"{"eq":{"low":3},"denoise":"strong"}"#
        let fx = try JSONDecoder().decode(AudioFx.self, from: Data(json.utf8))
        XCTAssertNil(fx.denoise)
        XCTAssertEqual(fx.extra["denoise"], .string("strong"))
        let text = String(decoding: try JSONEncoder().encode(fx), as: UTF8.self)
        XCTAssertTrue(text.contains("\"denoise\":\"strong\""))
    }
}
