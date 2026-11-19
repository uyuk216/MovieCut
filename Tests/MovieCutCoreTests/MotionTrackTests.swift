import XCTest
import CoreGraphics
@testable import MovieCutCore

/// 動きの追従(MotionTrack)。Vision は使わず、動く点を返す偽の追跡器で確かめる。
final class MotionTrackTests: XCTestCase {
    /// 中身を見ない 1 画素の画像(偽の追跡器に渡すだけ)。
    func dummyImage() -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    /// 毎コマ、中心が `path(t)` にある矩形を返す偽の追跡器。`lostFrames` のコマは nil を返す。
    final class FakeTracker: RectTracking {
        let path: (Double) -> (x: Double, y: Double)
        let lostFrames: Set<Int>
        var frame = -1
        var started: CGRect?
        init(path: @escaping (Double) -> (x: Double, y: Double), lostFrames: Set<Int> = []) {
            self.path = path; self.lostFrames = lostFrames
        }
        func start(rect: CGRect, image: CGImage) { started = rect; frame = 0 }
        func next(image: CGImage) -> CGRect? {
            frame += 1
            if lostFrames.contains(frame) { return nil }
            let p = path(Double(frame) / MotionTrack.sampleRate)
            return CGRect(x: p.x - 0.1, y: p.y - 0.1, width: 0.2, height: 0.2)
        }
    }

    func value(_ keys: [Keyframe], at t: Double) -> Double {
        Animation.value(of: "x", in: { var c = Clip(); c.keyframes["x"] = keys; return c }(), at: t)
    }

    func testTrackerStartsAtCentreRegionAndCollectsOneSamplePerTick() {
        let tracker = FakeTracker(path: { _ in (x: 0.5, y: 0.5) })
        let img = dummyImage()
        let s = MotionTrack.track(duration: 2, tracker: tracker) { _ in img }
        XCTAssertEqual(s.count, 21, "2 秒 × 10 回 + 1")
        XCTAssertEqual(tracker.started, MotionTrack.startRect)
        XCTAssertEqual(s[0]?.midX ?? 0, 0.5, accuracy: 1e-9)
    }

    func testKeyframesFollowAMovingPoint() {
        // 点は 1 秒あたり 0.2 ずつ右へ(0.5 → 0.7 → 0.9)
        let tracker = FakeTracker(path: { t in (x: 0.5 + 0.2 * t, y: 0.5) })
        let img = dummyImage()
        let s = MotionTrack.track(duration: 2, tracker: tracker) { _ in img }
        guard let k = MotionTrack.keyframes(samples: s, baseX: 0.3, baseY: 0.4) else { return XCTFail("キーが無い") }
        // 基準 0.3 + 追った量(前後二回の平滑化なので、遅れは出ない)
        XCTAssertEqual(value(k.x, at: 1.0), 0.3 + 0.2, accuracy: 0.02)
        XCTAssertEqual(value(k.x, at: 1.5), 0.3 + 0.3, accuracy: 0.02)
        XCTAssertLessThan(value(k.x, at: 0.5), value(k.x, at: 1.5), "右へ動く")
        XCTAssertEqual(value(k.y, at: 1.0), 0.4, accuracy: 0.01, "縦は動かない")
    }

    func testLostFramesHoldThePreviousPosition() {
        // 短い見失い(2 コマまで)は打ち切らず、従来どおり直前の位置を保持してつなぐ。
        // 3 コマ続く見失いは R4-5 で打ち切りに変わった(testTrackRunTruncatesOnLostStreak)。
        let tracker = FakeTracker(path: { t in (x: 0.5 + 0.2 * t, y: 0.5) }, lostFrames: [5, 6])
        let img = dummyImage()
        let s = MotionTrack.track(duration: 1, tracker: tracker) { _ in img }
        XCTAssertNil(s[5] ?? nil, "見失ったコマは nil")
        XCTAssertNil(s[6] ?? nil)
        guard let k = MotionTrack.keyframes(samples: s, baseX: 0.5, baseY: 0.5) else { return XCTFail() }
        // 見失っている間は、直前の値(= コマ 4 の位置)の近くに留まる(急に飛ばない)
        let a = value(k.x, at: 0.4), b = value(k.x, at: 0.8)
        XCTAssertLessThan(abs(b - a), 0.12, "見失いで飛ばない")
    }

    func testNoSamplesGivesNoKeyframes() {
        XCTAssertNil(MotionTrack.keyframes(samples: [nil, nil], baseX: 0.5, baseY: 0.5))
        var c = Clip(); c.type = .text
        XCTAssertFalse(MotionTrack.apply(samples: [nil], to: &c))
        XCTAssertNil(c.keyframes["x"])
    }

    func testApplyWritesOnceAndReportsNoChangeAfter() {
        let tracker = FakeTracker(path: { t in (x: 0.5 + 0.1 * t, y: 0.5 + 0.1 * t) })
        let img = dummyImage()
        let s = MotionTrack.track(duration: 1, tracker: tracker) { _ in img }
        var c = Clip(); c.type = .text; c.start = 0; c.duration = 1
        XCTAssertTrue(MotionTrack.apply(samples: s, to: &c))
        XCTAssertNotNil(c.keyframes["x"])
        XCTAssertNotNil(c.keyframes["y"])
        // 同じ追跡の結果を、今の位置を基準にもう一度書くと、位置がずれて変わる(Undo は 1 回ずつ)
        XCTAssertTrue(MotionTrack.apply(samples: s, to: &c))
        var d = Clip(); d.type = .text
        XCTAssertFalse(MotionTrack.apply(samples: [nil, nil], to: &d), "何も変わらないときは false")
    }

    func testSourceClipIsTheNearestVideoBelowAtTheStartTime() {
        var project = Project()
        var low = Clip(); low.type = .video; low.src = "a.mp4"; low.start = 0; low.duration = 10; low.srcDuration = 10
        var mid = Clip(); mid.type = .video; mid.src = "b.mp4"; mid.start = 0; mid.duration = 10; mid.srcDuration = 10
        var text = Clip(); text.type = .text; text.start = 2; text.duration = 3
        var top = Track(); top.clips = [text]
        var bottom = Track(); bottom.clips = [low]
        var middle = Track(); middle.clips = [mid]
        project.tracks = [bottom, middle, top]
        XCTAssertEqual(MotionTrack.sourceClip(for: text.id, in: project)?.src, "b.mp4", "一番手前(上に近い)の映像")
        // 映像が時刻にかかっていなければ元が無い
        project.tracks[1].clips[0].start = 20
        project.tracks[0].clips[0].start = 20
        XCTAssertNil(MotionTrack.sourceClip(for: text.id, in: project))
        // 映像は追従の対象にならない
        XCTAssertFalse(MotionTrack.canTrack(low))
        XCTAssertTrue(MotionTrack.canTrack(text))
    }

    // MARK: 見失いの打ち切り(R4-5)

    func testTrackRunTruncatesOnLostStreak() {
        // 見失いが 3 コマ続いたら、その先頭で打ち切る(以後のコマは結果に残らない)
        let tracker = FakeTracker(path: { t in (x: 0.5 + 0.2 * t, y: 0.5) }, lostFrames: [5, 6, 7])
        let img = dummyImage()
        let run = MotionTrack.trackRun(duration: 1, tracker: tracker) { _ in img }
        XCTAssertEqual(run.lostAt, 0.5)
        XCTAssertEqual(run.rects.count, 5)
        // 従来の track() も同じ打ち切り結果を返す
        let tracker2 = FakeTracker(path: { t in (x: 0.5 + 0.2 * t, y: 0.5) }, lostFrames: [5, 6, 7])
        XCTAssertEqual(MotionTrack.track(duration: 1, tracker: tracker2) { _ in img }.count, 5)
        // キーフレームも見失い以降は増えない
        let k = MotionTrack.keyframes(samples: run.rects, baseX: 0.5, baseY: 0.5)!
        XCTAssertEqual(k.x.last?.t, 0.4)
        XCTAssertEqual(k.x.count, 5)
    }

    func testTrackRunShortLossDoesNotTruncate() {
        // 2 コマだけの見失いは打ち切らず、従来どおり nil のまま続く
        let tracker = FakeTracker(path: { t in (x: 0.5 + 0.2 * t, y: 0.5) }, lostFrames: [5, 6])
        let img = dummyImage()
        let run = MotionTrack.trackRun(duration: 1, tracker: tracker) { _ in img }
        XCTAssertNil(run.lostAt)
        XCTAssertEqual(run.rects.count, 11)
        XCTAssertNil(run.rects[5] ?? nil)
        XCTAssertNotNil(run.rects[7] ?? nil)
    }

    func testKeyframesTrimTrailingLossStreak() {
        var samples: [CGRect?] = (0...4).map { k in CGRect(x: 0.4 + 0.01 * Double(k), y: 0.4, width: 0.2, height: 0.2) }
        samples += [CGRect?](repeating: nil, count: 6)
        let k = MotionTrack.keyframes(samples: samples, baseX: 0.5, baseY: 0.5)!
        XCTAssertEqual(k.x.count, 5, "末尾の見失い区間はキーにしない")
        XCTAssertEqual(k.x.last?.t, 0.4)
        // 末尾の欠落が 2 つだけなら、従来どおり直前の位置を保持して最後まで作る
        var samples2: [CGRect?] = (0...8).map { k in CGRect(x: 0.4 + 0.01 * Double(k), y: 0.4, width: 0.2, height: 0.2) }
        samples2 += [nil, nil]
        let k2 = MotionTrack.keyframes(samples: samples2, baseX: 0.5, baseY: 0.5)!
        XCTAssertEqual(k2.x.last?.t, 1.0)
    }
}
