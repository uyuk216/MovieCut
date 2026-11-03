import XCTest
@testable import MovieCutCore

/// ノイズゲート・リミッター(AudioFx.gate / limiter → GateProcessor / LimiterProcessor)。合成した信号だけで確かめる(決定的)。
final class GateLimiterTests: XCTestCase {
    let sr = 48_000.0

    func tone(seconds: Double, amp: Float, f: Double = 440) -> [Float] {
        (0..<Int(seconds * sr)).map { amp * Float(sin(2 * Double.pi * f * Double($0) / sr)) }
    }
    func rms(_ x: ArraySlice<Float>) -> Double {
        (x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, x.count))).squareRoot()
    }
    func run(_ x: [Float], _ fx: AudioFx, chunk: Int = 480_000) -> [Float] {
        var l = x, r = x
        let chain = AudioFxChain(fx, sr: sr)
        l.withUnsafeMutableBufferPointer { lp in
            r.withUnsafeMutableBufferPointer { rp in
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

    // MARK: ゲート

    func testGateSilencesQuietPartAndPassesLoudPart() {
        // 前半 1 秒: 小さい音(約 −60 dBFS)、後半 1 秒: 大きい音(約 −10 dBFS)
        let x = tone(seconds: 1, amp: 0.001) + tone(seconds: 1, amp: 0.3)
        let y = run(x, AudioFx(gate: -40))
        let n = Int(sr)
        XCTAssertLessThan(rms(y[(n / 2)..<n]), rms(x[(n / 2)..<n]) * 0.02, "小さい音は 34 dB 以上下がる")
        XCTAssertEqual(rms(y[(n + 24_000)..<(2 * n)]), rms(x[(n + 24_000)..<(2 * n)]), accuracy: 0.002, "大きい音は素通し")
    }

    func testGateClosesAfterHoldAndHysteresisKeepsItOpenNearThreshold() {
        // 大きい 0.5 秒のあと小さい 1 秒。ホールド 100 ms を過ぎたら閉じる
        let x = tone(seconds: 0.5, amp: 0.3) + tone(seconds: 1, amp: 0.001)
        let y = run(x, AudioFx(gate: -40))
        let tailStart = Int(0.5 * sr)
        XCTAssertGreaterThan(rms(y[(tailStart + 1_000)..<(tailStart + 3_000)]), rms(x[(tailStart + 1_000)..<(tailStart + 3_000)]) * 0.5, "ホールド中は開いたまま")
        XCTAssertLessThan(rms(y[(tailStart + 36_000)...]), 0.0002, "閉じる")
    }

    func testGateIsDeterministicAndKeepsStateAcrossChunks() {
        let x = tone(seconds: 0.5, amp: 0.3) + tone(seconds: 1, amp: 0.001) + tone(seconds: 0.5, amp: 0.3)
        XCTAssertEqual(run(x, AudioFx(gate: -40)), run(x, AudioFx(gate: -40)))
        let a = run(x, AudioFx(gate: -40), chunk: 480_000)
        let b = run(x, AudioFx(gate: -40), chunk: 7_001)
        XCTAssertEqual(a, b, "塊の大きさに依らない")
    }

    // MARK: リミッター

    func testLimiterNeverExceedsCeiling() {
        let ceil = Float(pow(10, -6.0 / 20))     // −6 dBFS
        var x = tone(seconds: 1, amp: 0.2) + tone(seconds: 1, amp: 0.95) + tone(seconds: 1, amp: 0.2)
        x[100] = 1.0; x[60_000] = -1.0     // 単発のピーク
        for chunk in [480_000, 5_003] {
            let y = run(x, AudioFx(limiter: -6), chunk: chunk)
            XCTAssertLessThanOrEqual(y.map { abs($0) }.max()!, ceil + 1e-6, "chunk \(chunk)")
        }
    }

    func testLimiterLeavesQuietSignalUntouchedAndRecovers() {
        let x = tone(seconds: 1, amp: 0.1)
        XCTAssertEqual(run(x, AudioFx(limiter: -6)), x, "天井より小さい音は変わらない")
        // 大きい音のあとの小さい音は、戻りのあとほぼ原音
        let z = tone(seconds: 0.2, amp: 0.95) + tone(seconds: 2, amp: 0.1)
        let y = run(z, AudioFx(limiter: -6))
        let s = Int(1.5 * sr)
        XCTAssertEqual(rms(y[s...]), rms(z[s...]), accuracy: 0.002)
    }

    func testLimiterIsSmoothWithoutHardClippingForModerateOvershoot() {
        // 天井を 3 dB 超える正弦波。ひずみが少ない = 倍率で抑えている
        let x = tone(seconds: 1, amp: 0.7)
        let y = run(x, AudioFx(limiter: -6))     // 天井 0.501
        let mid = y[24_000..<48_000]
        let peak = mid.map { abs($0) }.max()!
        XCTAssertLessThanOrEqual(peak, 0.5012)
        // 倍率で抑えていれば波形は正弦波のまま(実効値/ピーク ≈ 0.707)。切って平らにするとこの比が大きくなる
        XCTAssertEqual(rms(mid) / Double(peak), 0.7071, accuracy: 0.01)
    }

    // MARK: 編集・ファイル

    func clip() -> Clip { var c = Clip(); c.type = .audio; c.src = "a.wav"; c.start = 0; c.duration = 1; c.srcDuration = 1; return c }

    func testOffByDefaultAndNotInChain() {
        let fx = AudioFx()
        XCTAssertNil(fx.gateDb); XCTAssertNil(fx.limiterDb)
        XCTAssertFalse(AudioFx(gate: -40).isEmpty)
        XCTAssertTrue(AudioFx(gate: -40).hasChain)
        XCTAssertTrue(AudioFx(limiter: 0).isActive, "天井 0 dB も有効")
        XCTAssertTrue(AudioFx(gate: -40, limiter: -3).cacheToken.contains("gate=-40.0"))
        XCTAssertTrue(AudioFx(gate: -40, limiter: -3).cacheToken.contains("lim=-3.0"))
        XCTAssertEqual(AudioFx(gate: .nan, limiter: .infinity).isEmpty, true)
    }

    func testEditingClampsRoundsAndClears() {
        var c = clip()
        XCTAssertTrue(AudioFxEditing.setGate(&c, -33.3))
        XCTAssertEqual(c.audioFx?.gate, -33.5)
        XCTAssertFalse(AudioFxEditing.setGate(&c, -33.3), "同じ値は変化なし")
        XCTAssertTrue(AudioFxEditing.setGate(&c, -200))
        XCTAssertEqual(c.audioFx?.gate, -80)
        XCTAssertTrue(AudioFxEditing.setLimiter(&c, 5))
        XCTAssertEqual(c.audioFx?.limiter, 0)
        XCTAssertTrue(AudioFxEditing.setGate(&c, nil))
        XCTAssertTrue(AudioFxEditing.setLimiter(&c, nil))
        XCTAssertNil(c.audioFx, "外すと音声エフェクトごと消える")
    }

    func testWrittenOnlyWhenSetAndRoundTripsWithUnknownKeys() throws {
        var c = clip()
        let plain = String(decoding: try JSONEncoder().encode(c), as: UTF8.self)
        XCTAssertFalse(plain.contains("gate")); XCTAssertFalse(plain.contains("limiter"))
        AudioFxEditing.setGate(&c, -45); AudioFxEditing.setLimiter(&c, -2)
        let sorted = JSONEncoder(); sorted.outputFormatting = [.sortedKeys]   // 辞書の順番は実行ごとに変わるので、キーを並べて比べる
        let data = try sorted.encode(c)
        let back = try JSONDecoder().decode(Clip.self, from: data)
        XCTAssertEqual(back.audioFx?.gate, -45)
        XCTAssertEqual(back.audioFx?.limiter, -2)
        XCTAssertEqual(try sorted.encode(back), data, "往復でバイト一致")
        // 数でない値は捨てずに書き戻す
        let json = #"{"type":"audio","src":"a.wav","audioFx":{"gate":"x","future":1}}"#
        let c2 = try JSONDecoder().decode(Clip.self, from: Data(json.utf8))
        let out = String(decoding: try JSONEncoder().encode(c2), as: UTF8.self)
        XCTAssertTrue(out.contains("\"gate\"") && out.contains("future"))
    }
}
