import XCTest
import CoreGraphics
@testable import MovieCutCore

/// 自動リフレームの拡張(y 追従・ズーム・アスペクト・複数被写体)。既存の `AutoReframeTests` は触らない。
final class AutoReframeExtTests: XCTestCase {
    private func series(_ duration: Double, _ rects: (Double) -> [CGRect]) -> [SubjectSample] {
        let n = Int(duration * AutoReframe.sampleRate) + 1
        return (0..<n).map { k in let t = Double(k) / AutoReframe.sampleRate; return SubjectSample(t: t, rects: rects(t)) }
    }
    private func box(_ cx: Double, _ cy: Double, _ w: Double, _ h: Double) -> CGRect {
        CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }

    // 従来の plan(この拡張の前の式をそのまま写したもの)
    private func legacy(_ samples: [SubjectSample], _ w0: Double, _ h0: Double) -> (scale: Double, keys: [Keyframe], centers: [Double]) {
        let W = 1080.0, H = 1920.0
        let ww = (W / H) / (w0 / h0), half = ww / 2
        let scale = (H / h0) / min(W / w0, H / h0)
        let pw = (H / h0) * w0 / W
        var raw: [Double] = [], last = 0.5
        for s in samples { if let x = AutoReframe.focusX(s.rects) { last = x }; raw.append(last) }
        let dt = (samples[samples.count - 1].t - samples[0].t) / Double(samples.count - 1)
        let c = AutoReframe.smooth(raw, dt: dt, tau: 0.8).map { min(max($0, half), 1 - half) }
        return (scale, zip(samples, c).map { Keyframe(t: $0.0.t, v: 0.5 + (0.5 - $0.1) * pw) }, c)
    }

    func testDefaultOptionsMatchLegacyResult() throws {
        let s = series(10) { t in [box(0.5 + 0.3 * sin(t * 0.9), 0.5 + 0.2 * sin(t * 1.3), 0.1, 0.2), box(0.2, 0.3, 0.05, 0.08)] }
        let plan = try XCTUnwrap(AutoReframe.plan(samples: s, sourceWidth: 1920, sourceHeight: 1080))
        let old = legacy(s, 1920, 1080)
        XCTAssertEqual(plan.scale, old.scale, accuracy: 1e-12)
        XCTAssertEqual(plan.keys.count, old.keys.count)
        for (a, b) in zip(plan.keys, old.keys) { XCTAssertEqual(a.v, b.v, accuracy: 1e-12); XCTAssertEqual(a.t, b.t) }
        for (a, b) in zip(plan.centers, old.centers) { XCTAssertEqual(a, b, accuracy: 1e-12) }
        XCTAssertTrue(plan.yKeys.isEmpty, "窓の高さが素材いっぱいなので y は動かさない")
        XCTAssertTrue(plan.scaleKeys.isEmpty)
        XCTAssertEqual(plan.canvasWidth, 1080)
        XCTAssertEqual(plan.canvasHeight, 1920)
        var c = Clip(); c.type = .video
        AutoReframe.apply(plan, to: &c)
        XCTAssertNil(c.keyframes["y"]); XCTAssertNil(c.keyframes["scale"]); XCTAssertEqual(c.keyframes["x"]?.count, s.count)
    }

    func testAspectCanvasAndWindows() throws {
        XCTAssertTrue(ReframeAspect.portrait9x16.canvas(sourceWidth: 1920, sourceHeight: 1080) == (1080, 1920))
        XCTAssertTrue(ReframeAspect.portrait4x5.canvas(sourceWidth: 1920, sourceHeight: 1080) == (1080, 1350))
        XCTAssertTrue(ReframeAspect.square.canvas(sourceWidth: 1920, sourceHeight: 1080) == (1080, 1080))
        XCTAssertTrue(ReframeAspect.landscape16x9.canvas(sourceWidth: 1920, sourceHeight: 1080) == (1920, 1080))
        XCTAssertTrue(ReframeAspect.original.canvas(sourceWidth: 1920, sourceHeight: 1080) == (1920, 1080))
        XCTAssertTrue(ReframeAspect.original.canvas(sourceWidth: 1600, sourceHeight: 1200) == (1920, 1440))
        XCTAssertTrue(ReframeAspect.original.canvas(sourceWidth: 1080, sourceHeight: 1920) == (1080, 1920))

        let s = series(2) { _ in [box(0.5, 0.5, 0.1, 0.2)] }
        var o = ReframeOptions()
        for (aspect, ww) in [(ReframeAspect.portrait9x16, 0.31640625), (.portrait4x5, 0.45), (.square, 0.5625)] {
            o.aspect = aspect
            let p = try XCTUnwrap(AutoReframe.plan(samples: s, sourceWidth: 1920, sourceHeight: 1080, options: o))
            XCTAssertEqual(p.windowWidth, ww, accuracy: 1e-9, "\(aspect)")
            XCTAssertEqual(p.windowHeight, 1, accuracy: 1e-9)
            XCTAssertEqual(p.scale, Double(p.canvasHeight) / 1080 / (Double(p.canvasWidth) / 1920 < Double(p.canvasHeight) / 1080 ? Double(p.canvasWidth) / 1920 : Double(p.canvasHeight) / 1080), accuracy: 1e-9)
        }
        // 同じ比(16:9・元の比率)はズームなしだと何もしない。ズームありなら作れる
        for a in [ReframeAspect.landscape16x9, .original] {
            o.aspect = a; o.zoomEnabled = false
            XCTAssertNil(AutoReframe.plan(samples: s, sourceWidth: 1920, sourceHeight: 1080, options: o))
            o.zoomEnabled = true
            let p = try XCTUnwrap(AutoReframe.plan(samples: s, sourceWidth: 1920, sourceHeight: 1080, options: o))
            XCTAssertEqual(p.scale, 1, accuracy: 1e-9)
            XCTAssertEqual(p.canvasWidth, 1920)
        }
    }

    func testYFollowOnTallSourceStaysInsideAndKeepsSubjectInView() throws {
        // 縦長の素材(9:16)を正方形へ: 窓は縦に余裕がある。被写体は上から下へ動く
        var o = ReframeOptions(); o.aspect = .square
        let s = series(10) { t in [box(0.5, 0.2 + 0.6 * t / 10, 0.2, 0.1)] }
        let p = try XCTUnwrap(AutoReframe.plan(samples: s, sourceWidth: 1080, sourceHeight: 1920, options: o))
        XCTAssertEqual(p.windowHeight, (1080.0 / 1080.0) / (1920.0 / 1080.0) * 1, accuracy: 1e-9)   // 0.5625
        XCTAssertEqual(p.yKeys.count, s.count)
        let hh = p.windowHeight / 2
        for (i, smp) in s.enumerated() {
            let c = p.centersY[i]
            XCTAssertGreaterThanOrEqual(c, hh - 1e-9); XCTAssertLessThanOrEqual(c, 1 - hh + 1e-9)
            let b = smp.rects[0]
            XCTAssertGreaterThanOrEqual(Double(b.minY), c - hh - 1e-9, "見切れない t=\(smp.t)")
            XCTAssertLessThanOrEqual(Double(b.maxY), c + hh + 1e-9, "見切れない t=\(smp.t)")
            // y キー → 窓の中心の逆算
            let pictureH = 1920.0 / 1080.0                           // cover は幅合わせ(1080/1080 px 毎素材 px)。絵の高さ/キャンバス
            XCTAssertEqual(0.5 + (0.5 - c) * pictureH, p.yKeys[i].v, accuracy: 1e-9)
        }
        XCTAssertGreaterThan(p.centersY.last! - p.centersY.first!, 0.1)
        // y 追従をオフにすると y のキーは無い(窓は縦の中央)
        o.followY = false
        let p2 = try XCTUnwrap(AutoReframe.plan(samples: s, sourceWidth: 1080, sourceHeight: 1920, options: o))
        XCTAssertTrue(p2.yKeys.isEmpty)
        XCTAssertTrue(p2.centersY.allSatisfy { abs($0 - 0.5) < 1e-9 })
    }

    func testYSmoothingIsStrongerByDefault() throws {
        var o = ReframeOptions(); o.aspect = .square
        let s = series(12) { t in [box(0.5 + 0.1 * sin(t * 7), 0.5 + 0.1 * sin(t * 7), 0.1, 0.1)] }
        let p = try XCTUnwrap(AutoReframe.plan(samples: s, sourceWidth: 1080, sourceHeight: 1920, options: o))
        func amp(_ v: [Double]) -> Double { (v.max() ?? 0) - (v.min() ?? 0) }
        o.yTauScale = 1.0
        let same = try XCTUnwrap(AutoReframe.plan(samples: s, sourceWidth: 1080, sourceHeight: 1920, options: o))
        XCTAssertLessThan(amp(p.centersY), amp(same.centersY), "既定の縦(時定数 1.5 倍)は横と同じ時定数よりゆっくり(振れ幅が小さい)")
        XCTAssertEqual(ReframeOptions().yTauScale, 1.5)
    }

    func testZoomFollowsSubjectSizeWithinBounds() throws {
        var o = ReframeOptions(); o.zoomEnabled = true; o.zoomMin = 1; o.zoomMax = 1.6
        o.aspect = .square
        // 被写体が 0.3 → 0.1 へ小さくなる(遠ざかる): 寄る
        let s = series(10) { t in [box(0.5, 0.5, 0.3 - 0.2 * t / 10, 0.3 - 0.2 * t / 10)] }
        let p = try XCTUnwrap(AutoReframe.plan(samples: s, sourceWidth: 1920, sourceHeight: 1080, options: o))
        XCTAssertEqual(p.scaleKeys.count, s.count)
        for z in p.zooms { XCTAssertGreaterThanOrEqual(z, 1 - 1e-9); XCTAssertLessThanOrEqual(z, 1.6 + 1e-9) }
        for (k, z) in zip(p.scaleKeys, p.zooms) { XCTAssertEqual(k.v, p.scale * z, accuracy: 1e-9) }
        XCTAssertGreaterThan(p.zooms.last!, p.zooms.first! + 0.3)
        XCTAssertEqual(p.zooms.last!, 1.6, accuracy: 1e-9, "上限で止まる")
        // 逆に近づく(大きくなる)と引く
        let s2 = series(10) { t in [box(0.5, 0.5, 0.1 + 0.2 * t / 10, 0.1 + 0.2 * t / 10)] }
        let p2 = try XCTUnwrap(AutoReframe.plan(samples: s2, sourceWidth: 1920, sourceHeight: 1080, options: o))
        XCTAssertLessThan(p2.zooms.last!, p2.zooms.first!)
        // 窓は縮んだ分だけ小さく、x の窓の中心はその内側に収まる(縁に空きが出ない)
        for (i, c) in p.centers.enumerated() {
            let hw = p.windowWidth / p.zooms[i] / 2
            XCTAssertGreaterThanOrEqual(c, hw - 1e-9); XCTAssertLessThanOrEqual(c, 1 - hw + 1e-9)
        }
        // ズームしない(既定)と scale キーは無い
        let off = try XCTUnwrap(AutoReframe.plan(samples: s, sourceWidth: 1920, sourceHeight: 1080, options: { var d = ReframeOptions(); d.aspect = .square; return d }()))
        XCTAssertTrue(off.scaleKeys.isEmpty)
    }

    func testZoomDoesNotJitterOnNoisySize() throws {
        var o = ReframeOptions(); o.zoomEnabled = true
        let s = series(12) { t in let w = 0.2 + 0.03 * sin(t * 11); return [box(0.5, 0.5, w, w)] }
        let p = try XCTUnwrap(AutoReframe.plan(samples: s, sourceWidth: 1920, sourceHeight: 1080, options: o))
        let amp = p.zooms.max()! - p.zooms.min()!
        XCTAssertLessThan(amp, 0.1, "細かい大きさのゆれにズームが反応しすぎない")
    }

    func testSubjectModesChooseWindow() throws {
        var o = ReframeOptions(); o.aspect = .portrait4x5          // 窓の幅 0.45
        // 大きい被写体(0.62)と小さい被写体(0.3)
        let big = box(0.62, 0.5, 0.14, 0.3), small = box(0.3, 0.5, 0.06, 0.1)
        let s = series(6) { _ in [small, big] }
        o.subjectMode = .largest
        let l = try XCTUnwrap(AutoReframe.plan(samples: s, sourceWidth: 1920, sourceHeight: 1080, options: o))
        XCTAssertEqual(l.centers.last!, 0.62, accuracy: 0.01)
        o.subjectMode = .group
        let g = try XCTUnwrap(AutoReframe.plan(samples: s, sourceWidth: 1920, sourceHeight: 1080, options: o))
        let union = small.union(big)
        for (i, c) in g.centers.enumerated() {
            let hw = g.windowWidth / g.zooms[i] / 2
            XCTAssertLessThanOrEqual(c - hw, Double(union.minX) + 1e-9, "全員が窓に入る")
            XCTAssertGreaterThanOrEqual(c + hw, Double(union.maxX) - 1e-9)
        }
        XCTAssertEqual(g.centers.last!, Double(union.midX), accuracy: 0.01)
        // 従来(主被写体)は面積の重み付き平均
        o.subjectMode = .primary
        let pr = try XCTUnwrap(AutoReframe.plan(samples: s, sourceWidth: 1920, sourceHeight: 1080, options: o))
        XCTAssertEqual(pr.centers.last!, AutoReframe.focusX([small, big])!, accuracy: 0.01)
    }

    func testGroupModeContainsAllBoxesWithZoomWhenTheyFit() throws {
        var o = ReframeOptions(); o.aspect = .portrait4x5; o.subjectMode = .group; o.zoomEnabled = true; o.zoomMax = 2
        // 全員が窓(0.45)に入る距離。ズームは全員が入る範囲に抑えられる
        let a = box(0.40, 0.5, 0.05, 0.1), b = box(0.55, 0.5, 0.05, 0.1)
        let s = series(8) { _ in [a, b] }
        let g = try XCTUnwrap(AutoReframe.plan(samples: s, sourceWidth: 1920, sourceHeight: 1080, options: o))
        let u = a.union(b)
        for (i, c) in g.centers.enumerated() {
            let hw = g.windowWidth / g.zooms[i] / 2
            XCTAssertLessThanOrEqual(c - hw, Double(u.minX) + 1e-9); XCTAssertGreaterThanOrEqual(c + hw, Double(u.maxX) - 1e-9)
        }
    }

    func testApplyWritesYAndScaleKeys() throws {
        var o = ReframeOptions(); o.aspect = .square; o.zoomEnabled = true
        let s = series(6) { t in [box(0.5, 0.3 + 0.1 * t, 0.1 + 0.01 * t, 0.1 + 0.01 * t)] }
        let p = try XCTUnwrap(AutoReframe.plan(samples: s, sourceWidth: 1080, sourceHeight: 1920, options: o))
        var c = Clip(); c.type = .video; c.x = 0.3; c.y = 0.7; c.scale = 2
        AutoReframe.apply(p, to: &c)
        XCTAssertNil(c.x); XCTAssertNil(c.y)
        XCTAssertEqual(c.keyframes["x"]?.count, s.count)
        XCTAssertEqual(c.keyframes["y"]?.count, s.count)
        XCTAssertEqual(c.keyframes["scale"]?.count, s.count)
    }

    // MARK: Opus チェック指摘の回帰テスト

    /// 指摘1: 全員が入る窓は、被写体が動いても(平滑化の遅れがあっても)枠を窓に入れ続ける。ズームなし・枠が窓の90〜100%の帯。
    func testGroupWindowKeepsMovingBoxInsideWhenItFitsBand() throws {
        var o = ReframeOptions(); o.aspect = .portrait4x5; o.subjectMode = .group
        let s = series(2) { t in [box(0.25 + 0.15 * t, 0.5, 0.18, 0.1), box(0.25 + 0.15 * t + 0.24, 0.5, 0.18, 0.1)] }   // 枠の幅 0.42(窓 0.45 の93%)
        let p = try XCTUnwrap(AutoReframe.plan(samples: s, sourceWidth: 1920, sourceHeight: 1080, options: o))
        for (i, smp) in s.enumerated() {
            let u = smp.rects.dropFirst().reduce(smp.rects[0]) { $0.union($1) }
            let hw = p.windowWidth / 2
            XCTAssertLessThanOrEqual(p.centers[i] - hw, Double(u.minX) + 1e-9, "左が見切れ i=\(i)")
            XCTAssertGreaterThanOrEqual(p.centers[i] + hw, Double(u.maxX) - 1e-9, "右が見切れ i=\(i)")
        }
    }

    /// 指摘1(ズームあり): 上限いっぱいまで寄っても、動く被写体が窓から出ない。
    func testGroupZoomKeepsMovingBoxInside() throws {
        var o = ReframeOptions(); o.aspect = .portrait4x5; o.subjectMode = .group; o.zoomEnabled = true; o.zoomMax = 2
        let s = series(2) { t in [box(0.25 + 0.15 * t, 0.5, 0.18, 0.1), box(0.25 + 0.15 * t + 0.24, 0.5, 0.18, 0.1)] }
        let p = try XCTUnwrap(AutoReframe.plan(samples: s, sourceWidth: 1920, sourceHeight: 1080, options: o))
        for (i, smp) in s.enumerated() {
            let u = smp.rects.dropFirst().reduce(smp.rects[0]) { $0.union($1) }
            let hw = p.windowWidth / p.zooms[i] / 2
            XCTAssertLessThanOrEqual(p.centers[i] - hw, Double(u.minX) + 1e-9, "左が見切れ i=\(i)")
            XCTAssertGreaterThanOrEqual(p.centers[i] + hw, Double(u.maxX) - 1e-9, "右が見切れ i=\(i)")
        }
    }

    /// 指摘2: 検出人数が変わっても scale のキーに段差が出ない(上限も滑らかに効く)。
    func testGroupZoomLimitDoesNotStepWhenCountChanges() throws {
        var o = ReframeOptions(); o.aspect = .portrait4x5; o.subjectMode = .group; o.zoomEnabled = true
        let two = [box(0.45, 0.5, 0.06, 0.15), box(0.55, 0.5, 0.06, 0.15)]
        let three = two + [box(0.78, 0.5, 0.06, 0.15)]
        let s = series(12) { t in t < 6 ? two : three }
        let p = try XCTUnwrap(AutoReframe.plan(samples: s, sourceWidth: 1920, sourceHeight: 1080, options: o))
        XCTAssertFalse(p.scaleKeys.isEmpty)
        let steps = zip(p.scaleKeys.dropFirst(), p.scaleKeys).map { abs($0.v - $1.v) }
        XCTAssertLessThan(steps.max() ?? 0, 0.25, "scale キーが跳んでいる: \(steps.max() ?? 0)")
        // 上限そのものは守る(3人側は全員が窓に入る)
        let u = three.dropFirst().reduce(three[0]) { $0.union($1) }
        XCTAssertLessThanOrEqual(Double(u.width) * p.zooms.last!, p.windowWidth + 1e-9)
    }

    /// 指摘3: 検出が抜けたコマにも直前の枠でズーム上限がかかり、寄りすぎ・跳ねが起きない。
    func testGroupZoomLimitAppliesOnFramesWithoutDetection() throws {
        var o = ReframeOptions(); o.aspect = .portrait4x5; o.subjectMode = .group; o.zoomEnabled = true
        let big = box(0.5, 0.5, 0.1, 0.5), flat = box(0.5, 0.5, 0.38, 0.05)     // flat の上限は 0.45/(0.38×1.05)≈1.13
        var s = series(12) { t in t < 8 ? [big] : [flat] }
        let miss = 50                                                          // t = 10.0
        s[miss] = SubjectSample(t: s[miss].t, rects: [])
        let p = try XCTUnwrap(AutoReframe.plan(samples: s, sourceWidth: 1920, sourceHeight: 1080, options: o))
        let limit = 0.45 / (0.38 * 1.05)
        XCTAssertLessThanOrEqual(p.zooms[miss], limit + 1e-6, "抜けたコマが寄りすぎ")
        XCTAssertLessThan(abs(p.zooms[miss] - p.zooms[miss - 1]), 0.1)
        XCTAssertLessThan(abs(p.zooms[miss] - p.zooms[miss + 1]), 0.1)
    }

    /// 指摘4: 偶数丸めで比率がわずかにずれても、「元の比率・ズームなし」は計画を作らない。
    func testOriginalAspectWithEvenRoundingIsNoOp() {
        let s = series(2) { _ in [box(0.5, 0.5, 0.1, 0.2)] }
        var o = ReframeOptions(); o.aspect = .original
        XCTAssertTrue(ReframeAspect.original.canvas(sourceWidth: 1280, sourceHeight: 534) == (1920, 802))
        XCTAssertNil(AutoReframe.plan(samples: s, sourceWidth: 1280, sourceHeight: 534, options: o))
        XCTAssertNil(AutoReframe.plan(samples: s, sourceWidth: 1920, sourceHeight: 1080, options: o))
        // ズームありなら作る
        o.zoomEnabled = true
        XCTAssertNotNil(AutoReframe.plan(samples: s, sourceWidth: 1280, sourceHeight: 534, options: o))
        // 本当に比率が違えば(16:9 の素材を 4:5)作る
        o.zoomEnabled = false; o.aspect = .portrait4x5
        XCTAssertNotNil(AutoReframe.plan(samples: s, sourceWidth: 1280, sourceHeight: 534, options: o))
    }

    /// 指摘5(作業決定): primary + ズームの見切れ防止は主被写体(最大面積)だけを対象にし、離れた小さい被写体には引っぱられない。
    func testPrimaryZoomKeepsLargestBoxInsideNotUnion() throws {
        var o = ReframeOptions(); o.aspect = .portrait4x5; o.zoomEnabled = true; o.zoomMin = 1; o.zoomMax = 1
        let s = series(2) { t in [box(0.15 + 0.3 * t, 0.5, 0.2, 0.4), box(0.95, 0.5, 0.02, 0.04)] }
        let p = try XCTUnwrap(AutoReframe.plan(samples: s, sourceWidth: 1920, sourceHeight: 1080, options: o))
        let hw = p.windowWidth / 2
        for (i, smp) in s.enumerated() {
            let m = smp.rects[0]
            XCTAssertLessThanOrEqual(p.centers[i] - hw, Double(m.minX) + 1e-9, "主被写体が見切れ i=\(i)")
            XCTAssertGreaterThanOrEqual(p.centers[i] + hw, Double(m.maxX) - 1e-9, "主被写体が見切れ i=\(i)")
        }
        let f = try XCTUnwrap(AutoReframe.focus(s[0].rects, mode: .primary))
        XCTAssertEqual(f.box, s[0].rects[0])
    }
}
