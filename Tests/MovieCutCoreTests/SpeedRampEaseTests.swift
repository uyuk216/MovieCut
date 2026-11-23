import XCTest
@testable import MovieCutCore

/// 速度ランプのイージング(#14/#18): 点の `ease` で速度を補間する。直線は従来の台形計算と一致し、
/// 曲線は解析的な積分(`Ease.integral`)で素材時刻に直す。ファイルは ease が直線のとき従来と変わらない。
final class SpeedRampEaseTests: XCTestCase {
    // MARK: 道具

    private func numericIntegral(_ pts: [SpeedKey], upTo t: Double, steps: Int = 4000) -> Double {
        var sum = 0.0
        let h = t / Double(steps)
        for i in 0...steps {
            let w: Double = (i == 0 || i == steps) ? 1 : (i % 2 == 1 ? 4 : 2)
            sum += w * SpeedRamp.speed(pts, at: Double(i) * h)
        }
        return sum * h / 3
    }

    // MARK: Ease の積分

    func testEaseIntegralBasics() {
        XCTAssertEqual(Ease.linear.integral(1), 0.5, accuracy: 1e-12)
        XCTAssertEqual(Ease.linear.integral(0.5), 0.125, accuracy: 1e-12)
        XCTAssertEqual(Ease.hold.integral(1), 0, accuracy: 1e-12)
        XCTAssertEqual(Ease.bezier(0, 0, 1, 1).integral(1), 0.5, accuracy: 1e-9)   // 恒等曲線は直線と同じ
        XCTAssertEqual(Ease.easeInOut.integral(1), 0.5, accuracy: 1e-9)            // 対称な曲線
        XCTAssertLessThan(Ease.easeIn.integral(1), 0.5)                            // ゆっくり始まる = 前半は進まない
        XCTAssertGreaterThan(Ease.easeOut.integral(1), 0.5)
        XCTAssertEqual(Ease.easeIn.integral(0), 0, accuracy: 1e-12)
    }

    func testBezierIntegralMatchesNumeric() {
        // 解析的な積分が、apply の数値積分(Simpson)と一致する
        for e in [Ease.easeIn, .easeOut, .easeInOut, .bezier(0.34, 1.56, 0.64, 1), .bezier(0.7, 0, 0.84, 0)] {
            for u in [0.25, 0.5, 0.8, 1.0] {
                let n = 2000
                let h = u / Double(n)
                var sum = 0.0
                for i in 0...n {
                    let w: Double = (i == 0 || i == n) ? 1 : (i % 2 == 1 ? 4 : 2)
                    sum += w * e.apply(Double(i) * h)
                }
                XCTAssertEqual(e.integral(u), sum * h / 3, accuracy: 2e-3, "\(e) u=\(u)")
            }
        }
    }

    // MARK: 直線は従来どおり

    func testLinearEaseMatchesLegacyTrapezoid() {
        let pts = [SpeedKey(t: 0, v: 1), SpeedKey(t: 2, v: 3), SpeedKey(t: 4, v: 0.5)]
        XCTAssertEqual(SpeedRamp.speed(pts, at: 1), 2, accuracy: 1e-12)
        XCTAssertEqual(SpeedRamp.speed(pts, at: 3), 1.75, accuracy: 1e-12)
        XCTAssertEqual(SpeedRamp.integral(pts, upTo: 2), 4, accuracy: 1e-12)      // (1+3)/2 × 2
        XCTAssertEqual(SpeedRamp.integral(pts, upTo: 4), 7.5, accuracy: 1e-12)    // + (3+0.5)/2 × 2
        XCTAssertEqual(SpeedRamp.integral(pts, upTo: 1), 1.5, accuracy: 1e-12)    // (1+2)/2 × 1
        XCTAssertEqual(SpeedRamp.time(pts, forIntegral: 7.5), 4, accuracy: 1e-9)
    }

    // MARK: 曲線の速度と積分

    func testEasedSpeedEndpointsAndMidpoint() {
        let pts = [SpeedKey(t: 0, v: 1, ease: .easeIn), SpeedKey(t: 2, v: 3)]
        XCTAssertEqual(SpeedRamp.speed(pts, at: 0), 1, accuracy: 1e-12)           // 端点はキーの値そのまま
        XCTAssertEqual(SpeedRamp.speed(pts, at: 2), 3, accuracy: 1e-12)
        XCTAssertEqual(SpeedRamp.speed(pts, at: 1), 1 + 2 * Ease.easeIn.apply(0.5), accuracy: 1e-12)
        XCTAssertLessThan(SpeedRamp.speed(pts, at: 1), 2)                         // 直線の中間(2)より遅い
    }

    func testEasedIntegralMatchesNumericIntegration() {
        let cases: [[SpeedKey]] = [
            [SpeedKey(t: 0, v: 1, ease: .easeIn), SpeedKey(t: 2, v: 3)],
            [SpeedKey(t: 0, v: 3, ease: .easeOut), SpeedKey(t: 2, v: 0.5)],
            [SpeedKey(t: 0, v: 0.5, ease: .bezier(0.34, 1.56, 0.64, 1)), SpeedKey(t: 1.5, v: 4), SpeedKey(t: 3, v: 1)],
            [SpeedKey(t: 0, v: 2, ease: .easeInOut), SpeedKey(t: 4, v: 2.5)],
        ]
        for pts in cases {
            let d = pts.last!.t
            XCTAssertEqual(SpeedRamp.integral(pts, upTo: d), numericIntegral(pts, upTo: d), accuracy: 2e-3)
            XCTAssertEqual(SpeedRamp.integral(pts, upTo: d / 2), numericIntegral(pts, upTo: d / 2), accuracy: 2e-3)
        }
    }

    func testEasedIntegralOrdering() {
        // 速くなるランプ(1→3)では、ゆっくり始まる曲線は使う素材が少なく、ゆっくり終わる曲線は多い
        let lin = [SpeedKey(t: 0, v: 1), SpeedKey(t: 2, v: 3)]
        let ein = [SpeedKey(t: 0, v: 1, ease: .easeIn), SpeedKey(t: 2, v: 3)]
        let eout = [SpeedKey(t: 0, v: 1, ease: .easeOut), SpeedKey(t: 2, v: 3)]
        XCTAssertLessThan(SpeedRamp.integral(ein, upTo: 2), SpeedRamp.integral(lin, upTo: 2))
        XCTAssertGreaterThan(SpeedRamp.integral(eout, upTo: 2), SpeedRamp.integral(lin, upTo: 2))
    }

    func testHoldEaseKeepsStartSpeed() {
        let pts = [SpeedKey(t: 0, v: 2, ease: .hold), SpeedKey(t: 2, v: 4), SpeedKey(t: 4, v: 4)]
        XCTAssertEqual(SpeedRamp.speed(pts, at: 1.999), 2, accuracy: 1e-12)
        XCTAssertEqual(SpeedRamp.speed(pts, at: 2), 4, accuracy: 1e-12)
        XCTAssertEqual(SpeedRamp.integral(pts, upTo: 2), 4, accuracy: 1e-12)      // 2 秒 × 速度 2
        XCTAssertEqual(SpeedRamp.integral(pts, upTo: 4), 12, accuracy: 1e-12)
    }

    func testIntegralMonotonicAndInverseRoundtrip() {
        let pts = [SpeedKey(t: 0, v: 0.5, ease: .easeInOut), SpeedKey(t: 1.5, v: 3, ease: .bezier(0.7, 0, 0.84, 0)), SpeedKey(t: 3, v: 1)]
        var prev = 0.0
        for i in 0...30 {
            let v = SpeedRamp.integral(pts, upTo: Double(i) * 0.1)
            XCTAssertGreaterThanOrEqual(v, prev)                                  // 速度 > 0 なので単調
            prev = v
        }
        for t in [0.3, 1.0, 1.5, 2.2, 2.9] {
            XCTAssertEqual(SpeedRamp.time(pts, forIntegral: SpeedRamp.integral(pts, upTo: t)), t, accuracy: 1e-6)
        }
    }

    // MARK: 分割・整形で ease を保つ

    func testSplitPreservesBoundarySpeedAndEase() {
        let pts = [SpeedKey(t: 0, v: 1, ease: .easeIn), SpeedKey(t: 2, v: 3), SpeedKey(t: 4, v: 1)]
        let (left, right) = SpeedRamp.split(pts, at: 1)
        XCTAssertEqual(left.last?.t, 1)
        XCTAssertEqual(left.last?.v, SpeedRamp.speed(pts, at: 1))
        XCTAssertEqual(right.first?.t, 0)
        XCTAssertEqual(right.first?.v, SpeedRamp.speed(pts, at: 1))
        XCTAssertEqual(right.first?.ease, .easeIn)                                // 境目を含む区間の ease を引き継ぐ
        XCTAssertEqual(right.last?.t, 3)
        // 直線なら、分けても使う素材の長さは変わらない
        let lin = [SpeedKey(t: 0, v: 1), SpeedKey(t: 2, v: 3), SpeedKey(t: 4, v: 1)]
        let (ll, lr) = SpeedRamp.split(lin, at: 3)
        XCTAssertEqual(SpeedRamp.integral(ll, upTo: 3) + SpeedRamp.integral(lr, upTo: 1), SpeedRamp.integral(lin, upTo: 4), accuracy: 1e-9)
    }

    func testSanitizedPreservesEase() {
        let out = try! XCTUnwrap(SpeedRamp.sanitized([SpeedKey(t: 2, v: 3, ease: .easeOut), SpeedKey(t: 0.5, v: 1)], duration: 4))
        XCTAssertEqual(out.count, 4)
        XCTAssertEqual(out[0].t, 0)
        XCTAssertEqual(out[2].ease, .easeOut)
        XCTAssertEqual(out[3].t, 4)
        let ext = SpeedRamp.extendedHead(out, by: 1)
        XCTAssertEqual(ext.count, 5)
        XCTAssertEqual(ext[3].ease, .easeOut)
        XCTAssertEqual(ext[3].t, 3)
    }

    // MARK: ファイル互換

    func testSpeedKeyFileCompatibility() throws {
        // 直線だけのランプは従来と同じ JSON(ease を書かない)
        let lin = [SpeedKey(t: 0, v: 1), SpeedKey(t: 2, v: 3)]
        let json = String(decoding: try JSONEncoder().encode(lin), as: UTF8.self)
        XCTAssertFalse(json.contains("ease"), json)
        // 古いファイル(ease 無し)は直線として読む
        let old = try JSONDecoder().decode([SpeedKey].self, from: Data(#"[{"t":0,"v":1},{"t":2,"v":3}]"#.utf8))
        XCTAssertEqual(old, lin)
        // 曲線は往復で保たれる
        let curved = [SpeedKey(t: 0, v: 1, ease: .easeIn), SpeedKey(t: 2, v: 3, ease: .bezier(0.34, 1.56, 0.64, 1))]
        let back = try JSONDecoder().decode([SpeedKey].self, from: JSONEncoder().encode(curved))
        XCTAssertEqual(back, curved)
        // クリップの読み込みでも、古い speedRamp はそのまま使える
        let clip = try JSONDecoder().decode(Clip.self, from: Data(#"{"id":"x","type":"video","start":0,"duration":4,"speedRamp":[{"t":0,"v":1},{"t":4,"v":2}]}"#.utf8))
        XCTAssertEqual(clip.rampPoints?.map(\.ease), [.linear, .linear])
        XCTAssertEqual(clip.rampPoints?.map(\.v), [1, 2])
    }

    // MARK: ClipTiming との接続

    func testClipTimingWithEasedRamp() {
        var c = Clip(); c.id = "v"; c.type = .video; c.src = "/tmp/none.mp4"; c.start = 0; c.duration = 2; c.offset = 1; c.srcDuration = 100
        c.speedRamp = [SpeedKey(t: 0, v: 1, ease: .easeIn), SpeedKey(t: 2, v: 3)]
        let span = ClipTiming.sourceSpan(c)
        XCTAssertEqual(span, SpeedRamp.integral(c.rampPoints!, upTo: 2), accuracy: 1e-12)
        XCTAssertLessThan(span, 4)                                                // 直線(平均 2 × 2 秒 = 4)より短い
        XCTAssertEqual(ClipTiming.sourceTime(of: c, atClipTime: 0), 1, accuracy: 1e-12)
        XCTAssertEqual(ClipTiming.sourceTime(of: c, atClipTime: 2), 1 + span, accuracy: 1e-9)
        XCTAssertEqual(ClipTiming.clipTime(of: c, forSourceTime: 1 + span) ?? -1, 2, accuracy: 1e-6)
        XCTAssertEqual(ClipTiming.speed(of: c, atClipTime: 1), 1 + 2 * Ease.easeIn.apply(0.5), accuracy: 1e-12)
    }

    /// 行き過ぎるベジェ(バウンス風プリセット)でも、速度は正の範囲に収まり、積分は単調で逆変換が戻ること。
    func testOvershootingEaseKeepsSpeedPositiveAndIntegralMonotonic() {
        let pts = [SpeedKey(t: 0, v: 4, ease: .bezier(0.34, 1.56, 0.64, 1)), SpeedKey(t: 4, v: 0.25)]
        for i in 0...40 {
            let v = SpeedRamp.speed(pts, at: Double(i) / 10)
            XCTAssertGreaterThanOrEqual(v, 0.25, "t=\(Double(i) / 10)")
            XCTAssertLessThanOrEqual(v, 4, "t=\(Double(i) / 10)")
        }
        var prev = 0.0
        for i in 0...80 {
            let v = SpeedRamp.integral(pts, upTo: Double(i) / 20)
            XCTAssertGreaterThanOrEqual(v, prev - 1e-9, "積分が減った t=\(Double(i) / 20)")
            prev = v
        }
        let s = SpeedRamp.integral(pts, upTo: 2.0)
        XCTAssertEqual(SpeedRamp.time(pts, forIntegral: s), 2.0, accuracy: 0.01)
    }
}
