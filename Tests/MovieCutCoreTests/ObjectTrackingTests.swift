import XCTest
import CoreGraphics
@testable import MovieCutCore

/// オブジェクトトラッキング(W3-03 / 監査 #53): 収集(進捗・キャンセル)、結果の補間、
/// キーフレーム変換・追従適用(位置+大きさ/ぼかし矩形)、保存往復、Vision の疎通。
final class ObjectTrackingTests: XCTestCase {

    func dummyImage() -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    /// 毎コマ、中心が `path(t)` にある 0.2×0.2 の矩形を返す偽の追跡器。大きさは `size(t)` で変えられる。
    final class FakeTracker: RectTracking {
        let path: (Double) -> (x: Double, y: Double)
        let size: (Double) -> Double
        var frame = -1
        var started: CGRect?
        init(path: @escaping (Double) -> (x: Double, y: Double), size: @escaping (Double) -> Double = { _ in 0.2 }) {
            self.path = path; self.size = size
        }
        func start(rect: CGRect, image: CGImage) { started = rect; frame = 0 }
        func next(image: CGImage) -> CGRect? {
            frame += 1
            let p = path(Double(frame) / ObjectTracking.sampleRate)
            let s = size(Double(frame) / ObjectTracking.sampleRate)
            return CGRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s)
        }
    }

    let startRect = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)

    func collect(_ tracker: FakeTracker, duration: Double = 2) -> [CGRect?] {
        let img = dummyImage()
        return ObjectTracking.collect(duration: duration, startRect: startRect, tracker: tracker) { _ in img }!
    }

    // MARK: 収集

    func testCollectUsesCustomStartRectAndReportsProgress() {
        let tracker = FakeTracker(path: { _ in (x: 0.5, y: 0.5) })
        let img = dummyImage()
        var progress: [Double] = []
        let out = ObjectTracking.collect(duration: 1, startRect: startRect, tracker: tracker,
                                         frame: { _ in img }, progress: { progress.append($0) })
        XCTAssertEqual(tracker.started, startRect, "指定した開始矩形で追跡を始める(従来の中央固定ではない)")
        XCTAssertEqual(out?.count, 11)
        XCTAssertEqual(out?[0] ?? nil, startRect)
        XCTAssertEqual(progress.last, 1.0)
        XCTAssertEqual(progress, progress.sorted(), "進捗は単調")
    }

    func testCollectCancels() {
        let tracker = FakeTracker(path: { _ in (x: 0.5, y: 0.5) })
        let img = dummyImage()
        var calls = 0
        let out = ObjectTracking.collect(duration: 5, startRect: startRect, tracker: tracker,
                                         frame: { _ in img }, shouldCancel: { calls += 1; return calls > 3 })
        XCTAssertNil(out, "キャンセルしたら結果は nil(部分結果を適用しない)")
    }

    // MARK: 補間

    func testRectInterpolationAndGap() {
        let track = ObjectTrack(sourceClipId: "src", startRect: TrackRect(x: 0.1, y: 0.1, w: 0.2, h: 0.2), samples: [
            TrackSample(t: 0, rect: TrackRect(x: 0.1, y: 0.1, w: 0.2, h: 0.2)),
            TrackSample(t: 1, rect: TrackRect(x: 0.3, y: 0.1, w: 0.2, h: 0.2)),
            TrackSample(t: 5, rect: TrackRect(x: 0.9, y: 0.1, w: 0.2, h: 0.2)),
        ])
        let mid = track.rect(at: 0.5)
        XCTAssertEqual(Double(mid!.minX), 0.2, accuracy: 1e-9, "前後を線形補間")
        XCTAssertNil(track.rect(at: 3), "検出の間隔が広い中間は補間しない")
        XCTAssertEqual(Double(track.rect(at: 4.6)!.minX), 0.9, accuracy: 1e-9, "近い検出は maxGap まで使う")
        XCTAssertNil(ObjectTrack(sourceClipId: "s", startRect: TrackRect(x: 0, y: 0, w: 1, h: 1), samples: [TrackSample(t: 0, rect: nil)]).rect(at: 0))
    }

    // MARK: 追従の適用

    func testApplyFollowsPositionAndSize() {
        // 中心が右へ 0.2 動き、大きさが 2 倍(面積 4 倍)になる対象
        let rects = collect(FakeTracker(path: { t in (x: 0.5 + 0.1 * t, y: 0.5) }, size: { t in 0.2 + 0.1 * t }), duration: 2)
        let track = ObjectTracking.makeTrack(sourceClipId: "src", startRect: startRect, rects: rects)!
        var c = Clip(); c.type = .text; c.x = 0.3; c.y = 0.4; c.scale = 1; c.start = 0; c.duration = 2
        XCTAssertTrue(ObjectTracking.apply(track: track, to: &c))
        XCTAssertEqual(c.tracking, track, "追跡結果そのものが保存される")
        XCTAssertNotNil(c.keyframes["scale"], "大きさの変化もキーになる")
        let xEnd = Animation.value(of: "x", in: c, at: 2)
        XCTAssertEqual(xEnd, 0.3 + 0.2, accuracy: 0.03, "位置は開始時点のずれを保って追従")
        let sEnd = Animation.value(of: "scale", in: c, at: 2)
        XCTAssertEqual(sEnd, 2.0, accuracy: 0.15, "拡大は面積比の平方根(= 辺の比)")
        XCTAssertEqual(Animation.value(of: "y", in: c, at: 2), 0.4, accuracy: 0.02, "縦は動かない")
    }

    func testApplyPositionOnlyWritesNoScaleKeys() {
        let rects = collect(FakeTracker(path: { t in (x: 0.5 + 0.1 * t, y: 0.5) }), duration: 1)
        let track = ObjectTracking.makeTrack(sourceClipId: "src", startRect: startRect, rects: rects)!
        var c = Clip(); c.type = .image; c.start = 0; c.duration = 1
        XCTAssertTrue(ObjectTracking.apply(track: track, to: &c))
        XCTAssertNil(c.keyframes["scale"], "大きさが変わらなければ scale キーは作らない")
        XCTAssertNotNil(c.keyframes["x"])
    }

    func testVideoClipCanFollow() {
        // 従来の MotionTrack は映像クリップを追従対象にできなかった
        var v = Clip(); v.type = .video
        XCTAssertFalse(MotionTrack.canTrack(v))
        XCTAssertTrue(ObjectTracking.canFollow(v))
        let rects = collect(FakeTracker(path: { t in (x: 0.5 + 0.1 * t, y: 0.5) }), duration: 1)
        let track = ObjectTracking.makeTrack(sourceClipId: "src", startRect: startRect, rects: rects)!
        XCTAssertTrue(ObjectTracking.apply(track: track, to: &v))
    }

    func testBlurFollowerFollowsRect() {
        let blurStart = CGRect(x: 0.35, y: 0.25, width: 0.3, height: 0.3)   // 中心 (0.5, 0.4)
        let img = dummyImage()
        let rects = ObjectTracking.collect(duration: 1, startRect: blurStart,
                                           tracker: FakeTracker(path: { t in (x: 0.5 + 0.1 * t, y: 0.4) }, size: { _ in 0.3 })) { _ in img }!
        let track = ObjectTracking.makeTrack(sourceClipId: "src", startRect: blurStart, rects: rects)!
        let blur = ObjectTracking.makeBlurFollower(track: track, start: 5, duration: 1)
        XCTAssertEqual(blur.type, .blur)
        XCTAssertEqual(blur.start, 5)
        XCTAssertEqual(blur.tracking, track)
        // ぼかし範囲は矩形そのもの: 中心と大きさが対象に合う
        XCTAssertEqual(Animation.value(of: "x", in: blur, at: 1), 0.6, accuracy: 0.03)
        XCTAssertEqual(Animation.value(of: "y", in: blur, at: 1), 0.4, accuracy: 0.03)
        XCTAssertEqual(Animation.value(of: "w", in: blur, at: 1), 0.3, accuracy: 0.03)
        XCTAssertEqual(Animation.value(of: "h", in: blur, at: 0), 0.3, accuracy: 0.03)
    }

    func testClearFollow() {
        let rects = collect(FakeTracker(path: { t in (x: 0.5 + 0.1 * t, y: 0.5) }), duration: 1)
        let track = ObjectTracking.makeTrack(sourceClipId: "src", startRect: startRect, rects: rects)!
        var c = Clip(); c.type = .text; c.x = 0.3; c.y = 0.4
        _ = ObjectTracking.apply(track: track, to: &c)
        XCTAssertTrue(ObjectTracking.clearFollow(from: &c))
        XCTAssertNil(c.tracking)
        XCTAssertNil(c.keyframes["x"])
        XCTAssertFalse(ObjectTracking.clearFollow(from: &c), "追従が無ければ false")
    }

    func testSourceClipForVideoFollower() {
        var project = Project()
        var src = Clip(); src.type = .video; src.src = "a.mp4"; src.start = 0; src.duration = 10; src.srcDuration = 10
        var follower = Clip(); follower.type = .video; follower.src = "b.mp4"; follower.start = 2; follower.duration = 3
        var bottom = Track(); bottom.clips = [src]
        var top = Track(); top.clips = [follower]
        project.tracks = [bottom, top]
        XCTAssertEqual(ObjectTracking.sourceClip(for: follower.id, in: project)?.src, "a.mp4")
        // 自分自身しか下に無ければ元は無い
        project.tracks = [top]
        XCTAssertNil(ObjectTracking.sourceClip(for: follower.id, in: project))
    }

    // MARK: 保存

    func testTrackingRoundTripsAndIsOmittedWhenAbsent() throws {
        let rects = collect(FakeTracker(path: { t in (x: 0.5 + 0.1 * t, y: 0.5) }), duration: 1)
        let track = ObjectTracking.makeTrack(sourceClipId: "src", startRect: startRect, rects: rects)!
        var c = Clip(); c.type = .text; c.id = "follower"
        _ = ObjectTracking.apply(track: track, to: &c)
        var p = Project()
        var tr = Track(); tr.clips = [c]; p.tracks = [tr]
        let data = try p.encoded()
        XCTAssertTrue(String(data: data, encoding: .utf8)!.contains("\"tracking\""))
        let back = try Project.decode(from: data)
        XCTAssertEqual(back.allClips.first?.tracking, track)
        XCTAssertEqual(back, p)

        var plain = Project()
        var tr2 = Track(); var cc = Clip(); cc.type = .text; tr2.clips = [cc]; plain.tracks = [tr2]
        let plainJSON = String(data: try plain.encoded(), encoding: .utf8)!
        XCTAssertFalse(plainJSON.contains("\"tracking\""), "未使用のプロジェクトには書かない")
    }

    // MARK: Vision の疎通(合成画像)

    func testVisionTrackerFollowsSyntheticSquare() {
        // 128×128 の黒地に白い四角(32×32)が右へ 3px/コマで動く合成コマ列
        func frameImage(_ k: Int) -> CGImage {
            let ctx = CGContext(data: nil, width: 128, height: 128, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 16 + 3 * k, y: 48, width: 32, height: 32))
            return ctx.makeImage()!
        }
        let start = CGRect(x: 16.0 / 128, y: 48.0 / 128, width: 32.0 / 128, height: 32.0 / 128)
        var k = -1
        let out = ObjectTracking.collect(duration: 1, startRect: start, tracker: VisionRectTracker()) { _ in
            k += 1; return frameImage(k)
        }
        let rects = try! XCTUnwrap(out)
        XCTAssertEqual(rects.count, 11)
        let valid = rects.compactMap { $0 }
        XCTAssertGreaterThan(valid.count, 6, "大半のコマで追跡できる: \(valid.count)/11")
        if let first = valid.first, let last = valid.last {
            XCTAssertGreaterThan(Double(last.midX - first.midX), 0.08, "右への移動に追従する(期待 ≈ 0.23)")
        }
    }

    // MARK: 見失いの打ち切り(R4-5)

    /// 信頼つきの観測を返す偽の追跡器。`observations[k - 1]` がサンプル k(k >= 1)の観測。
    final class ConfidenceFakeTracker: RectTracking {
        let observations: [TrackObservation]
        private(set) var nextCalls = 0
        var started: CGRect?
        init(observations: [TrackObservation]) { self.observations = observations }
        func start(rect: CGRect, image: CGImage) { started = rect }
        func next(image: CGImage) -> CGRect? { nextObservation(image: image).rect }
        func nextObservation(image: CGImage) -> TrackObservation {
            nextCalls += 1
            return nextCalls - 1 < observations.count ? observations[nextCalls - 1] : TrackObservation(rect: nil, confidence: 0)
        }
    }

    /// 中心が (cx, 0.5) の 0.2×0.2 の矩形を、信頼度つきで返す観測。
    func confObs(_ cx: Double, _ confidence: Double) -> TrackObservation {
        TrackObservation(rect: CGRect(x: cx - 0.1, y: 0.4, width: 0.2, height: 0.2), confidence: confidence)
    }

    func testGateFilterTruncatesLowConfidenceStreak() {
        let good = TrackObservation(rect: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2), confidence: 0.9)
        let bad = TrackObservation(rect: CGRect(x: 0.9, y: 0.4, width: 0.2, height: 0.2), confidence: 0.2)
        let (rects, lost) = TrackingLossGate.filter(observations: [good, good, bad, bad, bad, good, good])
        XCTAssertEqual(lost, 2, "見失いは連続失敗の先頭")
        XCTAssertEqual(rects.count, 2, "見失い以降は結果に残らない")
        // 境界: 0.5 は採用、0.49 は不採用。矩形が無い・無効なものも不採用
        XCTAssertTrue(TrackingLossGate.isTrusted(rect: good.rect, confidence: 0.5))
        XCTAssertFalse(TrackingLossGate.isTrusted(rect: good.rect, confidence: 0.49))
        XCTAssertFalse(TrackingLossGate.isTrusted(rect: nil, confidence: 0.9))
        XCTAssertFalse(TrackingLossGate.isTrusted(rect: CGRect(x: 0, y: 0, width: 0, height: 0.2), confidence: 0.9))
        // 2 回までの失敗では打ち切らず、不採用の観測は nil になる(値は採用しない)
        let (r2, l2) = TrackingLossGate.filter(observations: [good, bad, bad, good])
        XCTAssertNil(l2)
        XCTAssertEqual(r2.count, 4)
        XCTAssertNil(r2[1] ?? nil)
        XCTAssertNil(r2[2] ?? nil)
        XCTAssertNotNil(r2[3] ?? nil)
    }

    func testCollectTruncatesOnLowConfidenceStreak() {
        // k=1〜4 は正常、k=5〜7 は低信頼で全く違う場所(静止矩形の焼き込みにあたる形)、
        // k=8 以降は回復する観測が用意してあっても、打ち切り後は消費されない
        var observations: [TrackObservation] = []
        for k in 1...20 {
            switch k {
            case 1...4: observations.append(confObs(0.5 + 0.01 * Double(k), 0.9))
            case 5...7: observations.append(confObs(0.95, 0.2))
            default: observations.append(confObs(0.6, 0.95))
            }
        }
        let tracker = ConfidenceFakeTracker(observations: observations)
        let img = dummyImage()
        let run = ObjectTracking.collectRun(duration: 2, startRect: startRect, tracker: tracker) { _ in img }
        let r = try! XCTUnwrap(run)
        XCTAssertEqual(r.lostAt ?? -1, 0.5, accuracy: 1e-9, "見失い時刻は連続失敗の先頭(k=5)")
        XCTAssertEqual(r.rects.count, 5, "見失い以降のサンプルは無い(k=0〜4)")
        XCTAssertEqual(tracker.nextCalls, 7, "見失い確定(k=7)で追跡を止める。以後の観測は消費しない")
        XCTAssertTrue(r.rects.allSatisfy { $0 == nil || abs(Double($0!.minX) - 0.85) > 1e-9 }, "低信頼の矩形は採用されていない")
        // 従来の collect も同じ打ち切り結果を返す
        let tracker2 = ConfidenceFakeTracker(observations: observations)
        XCTAssertEqual(ObjectTracking.collect(duration: 2, startRect: startRect, tracker: tracker2) { _ in img }?.count, 5)
    }

    func testCollectNormalHighConfidenceRunIsUnchanged() {
        let observations: [TrackObservation] = (1...20).map { confObs(0.5 + 0.01 * Double($0), 0.9) }
        let tracker = ConfidenceFakeTracker(observations: observations)
        let img = dummyImage()
        let run = ObjectTracking.collectRun(duration: 2, startRect: startRect, tracker: tracker) { _ in img }
        let r = try! XCTUnwrap(run)
        XCTAssertNil(r.lostAt, "正常に追えている間は見失いにならない")
        XCTAssertEqual(r.rects.count, 21, "従来どおり全サンプルが残る")
        let track = ObjectTracking.makeTrack(sourceClipId: "src", startRect: startRect, rects: r.rects, lostAt: r.lostAt)!
        XCTAssertNil(track.lostAt)
        var c = Clip(); c.type = .text; c.start = 0; c.duration = 2
        XCTAssertTrue(ObjectTracking.apply(track: track, to: &c))
        XCTAssertEqual(c.keyframes["x"]?.last?.t, 2.0, "キーは最後まで作られる(従来どおり)")
    }

    func testCollectTransientLowConfidenceIsNotAdoptedNorTruncated() {
        var observations: [TrackObservation] = (1...20).map { confObs(0.5 + 0.01 * Double($0), 0.9) }
        observations[4] = confObs(0.95, 0.2)   // k=5
        observations[5] = confObs(0.95, 0.2)   // k=6(2 回だけの失敗)
        let tracker = ConfidenceFakeTracker(observations: observations)
        let img = dummyImage()
        let run = ObjectTracking.collectRun(duration: 2, startRect: startRect, tracker: tracker) { _ in img }
        let r = try! XCTUnwrap(run)
        XCTAssertNil(r.lostAt, "短い失敗では打ち切らない")
        XCTAssertEqual(r.rects.count, 21)
        XCTAssertNil(r.rects[5] ?? nil, "低信頼の観測は採用しない(nil になる)")
        XCTAssertNil(r.rects[6] ?? nil)
        XCTAssertNotNil(r.rects[7] ?? nil, "回復後は従来どおり追跡が続く")
    }

    func testCollectTruncatesOnMissingFrameStreak() {
        // コマが取れない状態が続くのも見失い(開始後の欠落を失敗として数える)
        let tracker = FakeTracker(path: { t in (x: 0.5 + 0.1 * t, y: 0.5) })
        let img = dummyImage()
        let run = ObjectTracking.collectRun(duration: 2, startRect: startRect, tracker: tracker) { t in
            (t >= 0.5 && t <= 0.7) ? nil : img
        }
        let r = try! XCTUnwrap(run)
        XCTAssertEqual(r.lostAt ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertEqual(r.rects.count, 5)
    }

    func testKeyframesStopAtLostAt() {
        let rects: [CGRect?] = (0...20).map { k in CGRect(x: 0.4 + 0.01 * Double(k), y: 0.4, width: 0.2, height: 0.2) }
        let track = ObjectTracking.makeTrack(sourceClipId: "src", startRect: startRect, rects: rects, lostAt: 0.5)!
        XCTAssertEqual(track.lostAt, 0.5)
        XCTAssertTrue(track.isLost)
        XCTAssertEqual(track.samples.count, 5, "見失い以降のサンプルは持たない")
        XCTAssertEqual(track.samples.last?.t, 0.4)
        var c = Clip(); c.type = .text; c.start = 0; c.duration = 2
        XCTAssertTrue(ObjectTracking.apply(track: track, to: &c))
        XCTAssertEqual(c.tracking?.lostAt, 0.5, "見失い時刻がクリップに保存される")
        for (_, ks) in c.keyframes {
            XCTAssertTrue(ks.allSatisfy { $0.t < 0.5 }, "見失い以降にキーは増えない")
            XCTAssertEqual(ks.last?.t, 0.4)
        }
    }

    func testKeyframesIgnoreSamplesAfterLostAt() {
        // 保存済みの結果に見失い以降のサンプルが残っていても、キー化では使わない
        let samples = (0...20).map { k in TrackSample(t: Double(k) / 10, rect: TrackRect(x: 0.4 + 0.01 * Double(k), y: 0.4, w: 0.2, h: 0.2)) }
        let track = ObjectTrack(sourceClipId: "src", startRect: TrackRect(x: 0.4, y: 0.4, w: 0.2, h: 0.2), samples: samples, lostAt: 0.5)
        var c = Clip(); c.type = .text
        let ks = ObjectTracking.keyframes(track: track, follower: c)!
        XCTAssertTrue(ks.values.allSatisfy { $0.allSatisfy { $0.t < 0.5 } })
        XCTAssertEqual(ks["x"]?.last?.t, 0.4)
    }

    func testKeyframesTrimTrailingLossWithoutLostAt() {
        let head = (0...4).map { k in TrackSample(t: Double(k) / 10, rect: TrackRect(x: 0.4 + 0.01 * Double(k), y: 0.4, w: 0.2, h: 0.2)) }
        var c = Clip(); c.type = .text
        // 末尾の見失いが確定量以上続く列は、その先頭で切る
        let tail: [TrackSample] = (5...20).map { TrackSample(t: Double($0) / 10, rect: nil) }
        let track = ObjectTrack(sourceClipId: "src", startRect: TrackRect(x: 0.4, y: 0.4, w: 0.2, h: 0.2), samples: head + tail)
        let ks = ObjectTracking.keyframes(track: track, follower: c)!
        XCTAssertEqual(ks["x"]?.last?.t, 0.4, "末尾の見失い区間はキーにしない")
        // 末尾の欠落が 2 つだけなら、従来どおり直前の位置を保持して最後までキーを作る
        let body = (0...18).map { k in TrackSample(t: Double(k) / 10, rect: TrackRect(x: 0.4 + 0.01 * Double(k), y: 0.4, w: 0.2, h: 0.2)) }
        let track2 = ObjectTrack(sourceClipId: "src", startRect: TrackRect(x: 0.4, y: 0.4, w: 0.2, h: 0.2),
                                 samples: body + [TrackSample(t: 1.9, rect: nil), TrackSample(t: 2.0, rect: nil)])
        let ks2 = ObjectTracking.keyframes(track: track2, follower: c)!
        XCTAssertEqual(ks2["x"]?.last?.t, 2.0)
    }

    func testLostAtRoundTripsAndOldFilesDecode() throws {
        let samples = (0...4).map { k in TrackSample(t: Double(k) / 10, rect: TrackRect(x: 0.4 + 0.01 * Double(k), y: 0.4, w: 0.2, h: 0.2)) }
        let track = ObjectTrack(sourceClipId: "src", startRect: TrackRect(x: 0.4, y: 0.4, w: 0.2, h: 0.2), samples: samples, lostAt: 0.5)
        var c = Clip(); c.type = .text; c.id = "fol-lost"
        _ = ObjectTracking.apply(track: track, to: &c)
        var p = Project()
        var tr = Track(); tr.clips = [c]; p.tracks = [tr]
        let data = try p.encoded()
        let json = String(data: data, encoding: .utf8)!
        XCTAssertTrue(json.contains("\"lostAt\""), "見失い時刻がファイルに残る")
        let back = try Project.decode(from: data)
        XCTAssertEqual(back.allClips.first?.tracking, track)
        XCTAssertEqual(back.allClips.first?.tracking?.lostAt, 0.5)

        // 見失いの無い結果は lostAt を書かない(従来のファイル形のまま)
        let plainTrack = ObjectTrack(sourceClipId: "src", startRect: TrackRect(x: 0.4, y: 0.4, w: 0.2, h: 0.2), samples: samples)
        var c2 = Clip(); c2.type = .text; c2.id = "fol-plain"
        _ = ObjectTracking.apply(track: plainTrack, to: &c2)
        var p2 = Project()
        var tr2 = Track(); tr2.clips = [c2]; p2.tracks = [tr2]
        let json2 = String(data: try p2.encoded(), encoding: .utf8)!
        XCTAssertFalse(json2.contains("lostAt"), "未使用なら書かない")

        // 古いファイル(lostAt キー無し)の追跡結果が従来どおり読める
        let oldJSON = "{\"sourceClipId\":\"src\",\"startRect\":{\"x\":0.4,\"y\":0.4,\"w\":0.2,\"h\":0.2},\"samples\":[{\"t\":0,\"rect\":{\"x\":0.4,\"y\":0.4,\"w\":0.2,\"h\":0.2}}]}"
        let decoded = try JSONDecoder().decode(ObjectTrack.self, from: Data(oldJSON.utf8))
        XCTAssertNil(decoded.lostAt)
        XCTAssertEqual(decoded.samples.count, 1)
    }

    // MARK: Vision の実走(見失いの打ち切り)

    func syntheticFrame(size: Int, square: CGRect?) -> CGImage {
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        if let sq = square {
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(sq)
        }
        return ctx.makeImage()!
    }

    func testVisionSlowSquareIsNotTruncated() {
        // 低速域(R4-4 で IoU 0.839 だった条件に近い 3px/コマ)は最後まで追えて、見失いにならない
        let start = CGRect(x: 16.0 / 128, y: 48.0 / 128, width: 32.0 / 128, height: 32.0 / 128)
        var k = -1
        let run = ObjectTracking.collectRun(duration: 1, startRect: start, tracker: VisionRectTracker()) { _ in
            k += 1
            return syntheticFrame(size: 128, square: CGRect(x: 16 + 3 * k, y: 48, width: 32, height: 32))
        }
        let r = try! XCTUnwrap(run)
        XCTAssertNil(r.lostAt, "正常な追跡が信頼度ゲートで切られない")
        XCTAssertEqual(r.rects.count, 11)
    }

    func testVisionVanishingSquareIsTruncated() {
        // 途中で対象が消えたら、静止矩形を焼かずに見失いで打ち切る(R4-4 の失敗形)
        let start = CGRect(x: 16.0 / 128, y: 48.0 / 128, width: 32.0 / 128, height: 32.0 / 128)
        var k = -1
        let run = ObjectTracking.collectRun(duration: 1, startRect: start, tracker: VisionRectTracker()) { _ in
            k += 1
            return syntheticFrame(size: 128, square: k < 5 ? CGRect(x: 16 + 3 * k, y: 48, width: 32, height: 32) : nil)
        }
        let r = try! XCTUnwrap(run)
        let lostAt = try! XCTUnwrap(r.lostAt, "消えた対象は見失いとして打ち切られる")
        XCTAssertLessThan(r.rects.count, 11)
        XCTAssertEqual(r.rects.count, Int((lostAt * ObjectTracking.sampleRate).rounded()), "結果は見失い時刻の手前まで")
        let track = ObjectTracking.makeTrack(sourceClipId: "src", startRect: start, rects: r.rects, lostAt: r.lostAt)!
        XCTAssertEqual(track.lostAt, lostAt)
        var c = Clip(); c.type = .text
        let ks = ObjectTracking.keyframes(track: track, follower: c)!
        XCTAssertTrue(ks.values.allSatisfy { $0.allSatisfy { $0.t < lostAt } }, "見失い以降のキーは作られない")
    }
}


// MARK: - バグ確認 第2部 C16: 追従の適用と、正規化での無効矩形

private final class NullTracker: RectTracking {
    func start(rect: CGRect, image: CGImage) {}
    func next(image: CGImage) -> CGRect? { nil }
}

final class ObjectTrackingFollowupTests: XCTestCase {
    func testApplyKeepsUserScaleKeysWhenTrackHasConstantSize() {
        let track = ObjectTrack(sourceClipId: "src", startRect: TrackRect(x: 0.4, y: 0.4, w: 0.2, h: 0.2), samples: [
            TrackSample(t: 0, rect: TrackRect(x: 0.4, y: 0.4, w: 0.2, h: 0.2)),
            TrackSample(t: 1, rect: TrackRect(x: 0.5, y: 0.4, w: 0.2, h: 0.2)),
            TrackSample(t: 2, rect: TrackRect(x: 0.6, y: 0.4, w: 0.2, h: 0.2)),
        ])
        var c = Clip(); c.type = .text; c.x = 0.3; c.y = 0.4; c.scale = 1; c.start = 0; c.duration = 2
        c.keyframes["scale"] = [Keyframe(t: 0, v: 2)]
        XCTAssertTrue(ObjectTracking.apply(track: track, to: &c))
        XCTAssertEqual(c.keyframes["scale"], [Keyframe(t: 0, v: 2)], "大きさが一定の追従で、既存の scale キーを消さない")
    }
    func testNormalizedKeepsInvalidRectsAbsent() {
        let track = ObjectTrack(sourceClipId: "s", startRect: TrackRect(x: 0, y: 0, w: 1, h: 1), samples: [
            TrackSample(t: 0, rect: TrackRect(x: 0.1, y: 0.1, w: 0, h: 0.5)),
            TrackSample(t: 1, rect: TrackRect(x: 0.1, y: 0.1, w: 0.5, h: 0.5)),
        ])
        let n = track.normalized
        XCTAssertNil(n.samples[0].rect, "幅 0 の矩形は、正規化で小さな有効矩形に化けない")
        XCTAssertNotNil(n.samples[1].rect)
        var mask = ObjectMask(sourceClipId: "s", seedRect: TrackRect(x: 0, y: 0, w: 1, h: 1))
        mask.samples = [
            ObjectMaskSample(t: 0, rect: TrackRect(x: 0.1, y: 0.1, w: 0, h: 0.5)),
            ObjectMaskSample(t: 1, rect: TrackRect(x: 0.1, y: 0.1, w: 0.5, h: 0.5)),
        ]
        let mn = mask.normalized
        XCTAssertNil(mn.samples[0].rect)
        XCTAssertNotNil(mn.samples[1].rect)
    }
    func testTrackRunWithNonFiniteDurationDoesNotTrap() {
        let run = MotionTrack.trackRun(duration: .nan, tracker: NullTracker(), frame: { _ in nil })
        XCTAssertEqual(run.rects.count, 1)
    }
}
