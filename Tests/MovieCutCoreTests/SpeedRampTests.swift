import XCTest
@testable import MovieCutCore

/// 速度ランプ(時間で速さが変わる): 積分による時間の対応、分割・トリムの連続性、ファイルの書き方、整え方。
final class SpeedRampTests: XCTestCase {
    func video(_ id: String = "v", start: Double = 0, dur: Double, offset: Double = 0, src: Double = 100) -> Clip {
        var c = Clip(); c.id = id; c.type = .video; c.src = "/tmp/none.mp4"; c.start = start; c.duration = dur; c.offset = offset
        c.srcDuration = src
        return c
    }

    func project(_ clips: [Clip]) -> Project {
        var p = Project(); p.fps = 30; p.tracks = [Track(name: "t")]; p.tracks[0].clips = clips
        return p
    }

    /// 1 倍 → 0.25 倍へ 2 秒かけて直線で落とす(頭から 2 秒)。
    func ramp(_ dur: Double = 2, offset: Double = 0) -> Clip {
        var c = video(dur: dur, offset: offset)
        c.speedRamp = [SpeedKey(t: 0, v: 1), SpeedKey(t: dur, v: 0.25)]
        return c
    }

    // MARK: 積分と時間の対応

    func testConstantRampMatchesConstantSpeed() {
        var r = video(dur: 4, offset: 1)
        r.speedRamp = [SpeedKey(t: 0, v: 2), SpeedKey(t: 4, v: 2)]
        var k = video(dur: 4, offset: 1, src: 100); k.speed = 2
        XCTAssertEqual(ClipTiming.sourceSpan(r), ClipTiming.sourceSpan(k), accuracy: 1e-12)
        for t in stride(from: 0.0, through: 4, by: 0.5) {
            XCTAssertEqual(ClipTiming.sourceTime(of: r, atClipTime: t), ClipTiming.sourceTime(of: k, atClipTime: t), accuracy: 1e-12, "t \(t)")
        }
        XCTAssertEqual(r.effectiveSpeed, 2, accuracy: 1e-12)
        XCTAssertTrue(r.hasTimeRemap)
    }

    func testLinearRampSourceTimesAtKnownPoints() {
        let c = ramp(2, offset: 10)
        // ∫0^2 (1 → 0.25 の直線) = (1 + 0.25) / 2 × 2 = 1.25
        XCTAssertEqual(ClipTiming.sourceSpan(c), 1.25, accuracy: 1e-12)
        XCTAssertEqual(ClipTiming.sourceTime(of: c, atClipTime: 0), 10, accuracy: 1e-12)
        // ∫0^1 (1 − 0.375u) du = 1 − 0.1875 = 0.8125
        XCTAssertEqual(ClipTiming.sourceTime(of: c, atClipTime: 1), 10.8125, accuracy: 1e-12)
        XCTAssertEqual(ClipTiming.sourceTime(of: c, atClipTime: 2), 11.25, accuracy: 1e-12)
        XCTAssertEqual(c.effectiveSpeed, 0.625, accuracy: 1e-12, "平均の速さ = 1.25 / 2")
    }

    func testMappingIsStrictlyMonotonicAndInvertible() {
        let c = ramp(3, offset: 2)
        var prev = -Double.infinity
        for i in 0...600 {
            let t = Double(i) * 0.005
            let s = ClipTiming.sourceTime(of: c, atClipTime: t)
            XCTAssertGreaterThan(s, prev, "t \(t)")
            prev = s
            XCTAssertEqual(ClipTiming.clipTime(of: c, forSourceTime: s) ?? -1, t, accuracy: 1e-6, "逆変換 t \(t)")
        }
    }

    func testSourceConsumedEqualsIntegralAndSplitPreservesIt() throws {
        var c = ramp(4)
        c.speedRamp = [SpeedKey(t: 0, v: 0.5), SpeedKey(t: 1, v: 2), SpeedKey(t: 3, v: 1), SpeedKey(t: 4, v: 0.25)]
        let total = ClipTiming.sourceSpan(c)
        let (l, r) = try XCTUnwrap(ClipEditing.split(c, at: 1.7))
        XCTAssertEqual(ClipTiming.sourceSpan(l) + ClipTiming.sourceSpan(r), total, accuracy: 1e-9, "分けても使う素材の長さは同じ")
        // 境目の連続: 左の終わりの素材の時刻 = 右の頭の素材の時刻 = 元の同じ時刻
        XCTAssertEqual(ClipTiming.sourceTime(of: l, atClipTime: l.duration), ClipTiming.sourceTime(of: r, atClipTime: 0), accuracy: 1e-9)
        XCTAssertEqual(ClipTiming.sourceTime(of: r, atClipTime: 0), ClipTiming.sourceTime(of: c, atClipTime: 1.7), accuracy: 1e-9)
        // 右の断片の中も元と一致
        for t in [0.0, 0.4, 1.0, 2.2] {
            XCTAssertEqual(ClipTiming.sourceTime(of: r, atClipTime: t), ClipTiming.sourceTime(of: c, atClipTime: 1.7 + t), accuracy: 1e-9, "右 t \(t)")
        }
    }

    func testTrimLeftAndTrimAfterKeepContinuity() throws {
        let c = ramp(2, offset: 0)
        let p = project([c])
        // 頭を 0.5 秒進める(吸着なし)
        let left = ClipEditing.trimLeft(in: p, clipId: "v", deltaT: 0.5, playhead: 0, pps: 100, snapEnabled: false).project.allClips[0]
        XCTAssertEqual(left.duration, 1.5, accuracy: 1e-9)
        XCTAssertEqual(left.offset, ClipTiming.sourceTime(of: c, atClipTime: 0.5), accuracy: 1e-9, "頭の素材の時刻は元の 0.5 秒の所")
        XCTAssertEqual(ClipTiming.sourceTime(of: left, atClipTime: 0), ClipTiming.sourceTime(of: c, atClipTime: 0.5), accuracy: 1e-9)
        // 終わりを切る: 1 秒の時点で後ろを落とす
        let after = try XCTUnwrap(ClipEditing.trimAfter(in: p, clipId: "v", at: 1)).allClips[0]
        XCTAssertEqual(after.duration, 1, accuracy: 1e-9)
        XCTAssertEqual(ClipTiming.sourceTime(of: after, atClipTime: 1), ClipTiming.sourceTime(of: c, atClipTime: 1), accuracy: 1e-9)
    }

    func testTrimRightClampsToSourceEnd() {
        var c = ramp(2, offset: 0)
        c.srcDuration = 1.0       // 素材は 1 秒しかない(ランプで 1 秒ぶん使うのは約 1.25 秒 → 途中まで)
        let p = project([c])
        let r = ClipEditing.trimRight(in: p, clipId: "v", deltaT: 10, playhead: 0, pps: 100, snapEnabled: false).project.allClips[0]
        XCTAssertLessThanOrEqual(ClipTiming.sourceSpan(r), 1.0 + 1e-9, "素材の終わりを越えない")
        XCTAssertLessThan(r.duration, 2)
    }

    // MARK: ファイル・整え方・編集

    func testRampRoundTripsAndOnlyWrittenWhenSet() throws {
        let c = ramp(2)
        let data = try JSONEncoder().encode(c)
        XCTAssertEqual(try JSONDecoder().decode(Clip.self, from: data), c)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"speedRamp\""))
        let plain = video(dur: 2)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(plain), as: UTF8.self).contains("speedRamp"))
    }

    func testFrameBlendFlagWrittenOnlyWhenTrue() throws {
        var c = video(dur: 2); c.speed = 0.5
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(c), as: UTF8.self).contains("frameBlend"))
        c.frameBlend = true
        let s = String(decoding: try JSONEncoder().encode(c), as: UTF8.self)
        XCTAssertTrue(s.contains("\"frameBlend\":true"))
        XCTAssertEqual(try JSONDecoder().decode(Clip.self, from: Data(s.utf8)).frameBlend, true)
        XCTAssertTrue(ClipTiming.blendsFrames(c, atClipTime: 0.5))
        c.speed = 1
        XCTAssertFalse(ClipTiming.blendsFrames(c, atClipTime: 0.5), "速度 1 では混ぜない")
    }

    func testSanitizeSortsClampsAndAddsEndpoints() throws {
        let pts = [SpeedKey(t: 3, v: 9), SpeedKey(t: 1, v: 0.01), SpeedKey(t: .nan, v: 1)]
        let out = try XCTUnwrap(SpeedRamp.sanitized(pts, duration: 4))
        XCTAssertEqual(out.map(\.t), [0, 1, 3, 4])
        XCTAssertEqual(out.map(\.v), [0.25, 0.25, 4, 4], "速度は 0.25〜4 に収め、端は近い点の値")
        XCTAssertNil(SpeedRamp.sanitized([], duration: 4))
        XCTAssertNil(SpeedRamp.sanitized([SpeedKey(t: 0, v: 1)], duration: 0))
    }

    func testReverseIsIgnoredWhileRampIsSet() {
        var c = ramp(2)
        c.reverse = true
        XCTAssertFalse(c.effectiveReverse)
        XCTAssertNil(SpeedRamp.sanitized([], duration: 2))
        var probe = c
        XCTAssertFalse(SpeedEditing.setReverse(&probe, true), "ランプがあるあいだは逆再生にできない")
    }

    func testSetRampNilKeepsSourceSpanAsConstantSpeed() {
        var c = ramp(2)
        let span = ClipTiming.sourceSpan(c)
        XCTAssertTrue(SpeedEditing.setRamp(&c, nil))
        XCTAssertNil(c.speedRamp)
        XCTAssertEqual(c.duration, 2, "長さは変えない")
        XCTAssertEqual(ClipTiming.sourceSpan(c), span, accuracy: 1e-9, "使う素材の長さは同じ")
        XCTAssertFalse(SpeedEditing.setRamp(&c, nil), "同じ操作は変化なし")
    }

    func testSetRampFromConstantSpeedKeepsGeometry() throws {
        var c = video(dur: 3, offset: 0); c.speed = 2
        let before = ClipTiming.sourceSpan(c)
        XCTAssertTrue(SpeedEditing.setRamp(&c, [SpeedKey(t: 0, v: 2), SpeedKey(t: 3, v: 2)]))
        XCTAssertNil(c.speed)
        XCTAssertEqual(ClipTiming.sourceSpan(c), before, accuracy: 1e-12)
    }
}
