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
}
