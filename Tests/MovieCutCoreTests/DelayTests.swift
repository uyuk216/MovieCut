import XCTest
@testable import MovieCutCore

/// ディレイ/エコー(AudioFx.delay → DelayProcessor)。合成した信号だけで確かめる(決定的)。
final class DelayTests: XCTestCase {
    let sr = 48_000.0

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

    // MARK: 設定値

    func testDefaultsAndClamps() {
        let d = AudioFx.Delay()
        XCTAssertEqual(d.timeSeconds, 0.25)
        XCTAssertEqual(d.feedbackValue, 0.35)
        XCTAssertEqual(d.mix, 0.3)
        XCTAssertTrue(d.isActive)
        XCTAssertEqual(AudioFx.Delay(time: 99).timeSeconds, 2)
        XCTAssertEqual(AudioFx.Delay(time: 0).timeSeconds, 0.01)
        XCTAssertEqual(AudioFx.Delay(feedback: 5).feedbackValue, 0.9, "1 以上は発振するので 0.9 が上限")
        XCTAssertEqual(AudioFx.Delay(mix: -1).mix, 0)
        XCTAssertFalse(AudioFx.Delay(mix: 0).isActive)
        XCTAssertFalse(AudioFx.Delay(enabled: false).isActive)
    }

    func testRoundTripAndEmpty() throws {
        XCTAssertTrue(AudioFx().isEmpty)
        let fx = AudioFx(delay: AudioFx.Delay(time: 0.5, feedback: 0.4, mix: 0.2))
        XCTAssertFalse(fx.isEmpty)
        XCTAssertTrue(fx.isActive)
        XCTAssertTrue(fx.hasChain)
        let data = try JSONEncoder().encode(fx)
        let back = try JSONDecoder().decode(AudioFx.self, from: data)
        XCTAssertEqual(back, fx)
        XCTAssertTrue(fx.cacheToken.contains("delay=0.5,0.4,0.2"))
    }

    func testEditing() {
        var c = Clip(); c.type = .audio
        XCTAssertTrue(AudioFxEditing.setDelayEnabled(&c, true))
        XCTAssertEqual(c.audioFx?.delay?.timeSeconds, AudioFx.Delay.defaultTime)
        XCTAssertTrue(c.audioFx?.delay?.isActive ?? false)
        XCTAssertTrue(AudioFxEditing.setDelay(&c, .time, 9))
        XCTAssertEqual(c.audioFx?.delay?.timeSeconds, 2, "範囲に収める")
        XCTAssertTrue(AudioFxEditing.setDelay(&c, .mix, 0.456))
        XCTAssertEqual(c.audioFx?.delay?.mix ?? 0, 0.46, accuracy: 1e-9, "小数 2 桁に丸める")
        XCTAssertTrue(AudioFxEditing.setDelayEnabled(&c, false))
        XCTAssertFalse(c.audioFx?.delay?.isActive ?? true, "オフは設定を残したまま切る")
        XCTAssertNotNil(c.audioFx?.delay)
    }

    // MARK: 信号処理

    func testImpulseEchoesDecay() {
        // 間隔 0.01 秒 = 480 サンプル。インパルス 1 本 → 0.5, 0.25, 0.125 と半分ずつ弱くなる
        var x = [Float](repeating: 0, count: 2000); x[0] = 1
        let fx = AudioFx(delay: AudioFx.Delay(time: 0.01, feedback: 0.5, mix: 0.5))
        let y = run(x, fx)
        XCTAssertEqual(y[0], 0.5, accuracy: 1e-5, "原音は (1 − mix)")
        XCTAssertEqual(y[480], 0.5, accuracy: 1e-5, "1 回目のエコー")
        XCTAssertEqual(y[960], 0.25, accuracy: 1e-5, "2 回目は feedback 倍")
        XCTAssertEqual(y[1440], 0.125, accuracy: 1e-5)
        XCTAssertEqual(y[100], 0, "間隔以外の所には出ない")
    }

    func testNoFeedbackSingleEcho() {
        var x = [Float](repeating: 0, count: 2000); x[0] = 1
        let fx = AudioFx(delay: AudioFx.Delay(time: 0.01, feedback: 0, mix: 0.4))
        let y = run(x, fx)
        XCTAssertEqual(y[480], 0.4, accuracy: 1e-5)
        XCTAssertEqual(y[960], 0, "繰り返し 0 では 1 回だけ")
    }

    func testSilenceStaysSilentAndChunksMatch() {
        let x = [Float](repeating: 0, count: 5000)
        let fx = AudioFx(delay: AudioFx.Delay())
        XCTAssertTrue(run(x, fx).allSatisfy { $0 == 0 })
        // 塊を分けても同じ(状態が続く)
        var tone = [Float](repeating: 0, count: 5000); tone[0] = 1; tone[2000] = 0.5
        XCTAssertEqual(run(tone, fx), run(tone, fx, chunk: 100))
    }

    func testStereoChannelsAreIndependent() {
        var l = [Float](repeating: 0, count: 1200); l[0] = 1
        var r = [Float](repeating: 0, count: 1200)
        let chain = AudioFxChain(AudioFx(delay: AudioFx.Delay(time: 0.01, feedback: 0.5, mix: 0.5)), sr: sr)
        l.withUnsafeMutableBufferPointer { lp in
            r.withUnsafeMutableBufferPointer { rp in chain.process(lp.baseAddress!, rp.baseAddress!, 1200) }
        }
        XCTAssertEqual(l[480], 0.5, accuracy: 1e-5)
        XCTAssertTrue(r.allSatisfy { $0 == 0 }, "左だけの音は右へ漏れない")
    }

    func testDisabledOrZeroMixPassesThrough() {
        var x = [Float](repeating: 0, count: 100); x[0] = 0.8
        XCTAssertEqual(run(x, AudioFx(delay: AudioFx.Delay(mix: 0))), x)
        XCTAssertEqual(run(x, AudioFx(delay: AudioFx.Delay(enabled: false))), x)
        XCTAssertEqual(run(x, AudioFx()), x)
    }
}
