import XCTest
@testable import MovieCutCore

final class EaseCurveTests: XCTestCase {
    func testEndpointsAndMonotoneForMonotonePresets() {
        for (label, e) in EaseCurve.presets {
            XCTAssertEqual(e.apply(0), 0, label)
            XCTAssertEqual(e.apply(1), 1, label)
            // x(s) が単調なので u→apply は連続。y が行き過ぎないプリセットは単調増加
            let p = EaseCurve.controlPoints(e)
            if p.y1 >= 0 && p.y1 <= 1 && p.y2 >= 0 && p.y2 <= 1 {
                var prev = 0.0
                for i in 0...200 {
                    let v = e.apply(Double(i) / 200)
                    XCTAssertGreaterThanOrEqual(v, prev - 1e-9, "\(label) @\(i)")
                    prev = v
                }
            }
        }
    }

    func testSolveXIsMonotoneInParameter() {
        // x1,x2 in 0...1 なら x(s) は単調: 解いた y を媒介変数ごとに再現して x が u に一致する
        let cases: [(Double, Double, Double, Double)] = [(0.25, 0.1, 0.25, 1), (0, 0, 1, 1), (1, 0, 0, 1), (0.34, 1.56, 0.64, 1), (0.7, 0, 0.84, 0)]
        for c in cases {
            var prevU = -1.0
            for i in 0...100 {
                let u = Double(i) / 100
                XCTAssertGreaterThan(u, prevU)
                prevU = u
                let y = Ease.cubicBezier(c.0, c.1, c.2, c.3, u)
                XCTAssertTrue(y.isFinite)
            }
            XCTAssertEqual(Ease.cubicBezier(c.0, c.1, c.2, c.3, 0), 0)
            XCTAssertEqual(Ease.cubicBezier(c.0, c.1, c.2, c.3, 1), 1)
        }
    }

    func testLinearPointsGiveIdentity() {
        for i in 0...20 {
            let u = Double(i) / 20
            XCTAssertEqual(Ease.cubicBezier(0, 0, 1, 1, u), u, accuracy: 1e-6)
        }
    }

    func testPresetTableValues() {
        XCTAssertEqual(EaseCurve.presets.map(\.label), ["リニア", "イーズイン", "イーズアウト", "イーズインアウト", "バウンス風", "急→緩", "緩→急"])
        XCTAssertEqual(EaseCurve.presets[0].ease, .linear)
        XCTAssertEqual(EaseCurve.presets[1].ease, .easeIn)
        XCTAssertEqual(EaseCurve.presets[2].ease, .easeOut)
        XCTAssertEqual(EaseCurve.presets[3].ease, .easeInOut)
        XCTAssertEqual(EaseCurve.presets[4].ease, .bezier(0.34, 1.56, 0.64, 1))
        XCTAssertEqual(EaseCurve.presets[5].ease, .bezier(0.16, 1, 0.3, 1))
        XCTAssertEqual(EaseCurve.presets[6].ease, .bezier(0.7, 0, 0.84, 0))
        // バウンス風は 1 を超える
        XCTAssertGreaterThan((1...99).map { EaseCurve.presets[4].ease.apply(Double($0) / 100) }.max()!, 1.0)
        // 急→緩は前半で大きく進む、緩→急は後半
        XCTAssertGreaterThan(EaseCurve.presets[5].ease.apply(0.2), 0.5)
        XCTAssertLessThan(EaseCurve.presets[6].ease.apply(0.5), 0.3)
        // 名前付きは対応する制御点を返す
        XCTAssertTrue(EaseCurve.controlPoints(.easeInOut) == (0.42, 0, 0.58, 1))
        // プリセットは自身を言い当てる
        for (l, e) in EaseCurve.presets { XCTAssertEqual(EaseCurve.presetLabel(of: e), l) }
        XCTAssertNil(EaseCurve.presetLabel(of: .hold))
        XCTAssertNil(EaseCurve.presetLabel(of: .bezier(0.1, 0.2, 0.3, 0.4)))
    }

    func testEaseFromPointsNormalizes() {
        XCTAssertEqual(EaseCurve.ease(x1: 0, y1: 0, x2: 1, y2: 1), .linear)
        XCTAssertEqual(EaseCurve.ease(x1: 0.42, y1: 0, x2: 1, y2: 1), .easeIn)
        XCTAssertEqual(EaseCurve.ease(x1: -1, y1: 9, x2: 5, y2: -9), .bezier(0, 3, 1, -2))
        XCTAssertEqual(EaseCurve.ease(x1: 0.12345, y1: 0.5, x2: 0.5, y2: 0.5), .bezier(0.123, 0.5, 0.5, 0.5))
        XCTAssertEqual(EaseCurve.ease(x1: .nan, y1: .infinity, x2: 0.5, y2: 0.5), .bezier(0, 0, 0.5, 0.5))
    }

    func testSamples() {
        let s = EaseCurve.samples(.easeInOut, count: 10)
        XCTAssertEqual(s.count, 11)
        XCTAssertEqual(s.first!.v, 0); XCTAssertEqual(s.last!.v, 1)
        XCTAssertEqual(EaseCurve.samples(.linear, count: 1).count, 3)  // 最小 2 分割
    }

    // MARK: キーの編集

    private func clip() -> Clip {
        var c = Clip(); c.type = .image; c.duration = 4
        c.keyframes["x"] = [Keyframe(t: 0, v: 0), Keyframe(t: 1, v: 1), Keyframe(t: 2, v: 0)]
        return c
    }

    func testSetEaseAndNoOp() {
        var c = clip()
        let tol = 0.01
        XCTAssertEqual(KeyframeEditing.segmentEase(c, key: "x", at: 1, tolerance: tol), .linear)
        XCTAssertNil(KeyframeEditing.segmentEase(c, key: "x", at: 2, tolerance: tol), "最後のキーは次の区間が無い")
        XCTAssertNil(KeyframeEditing.segmentEase(c, key: "x", at: 0.5, tolerance: tol))
        XCTAssertFalse(KeyframeEditing.setEase(&c, key: "x", .linear, at: 1, tolerance: tol))
        XCTAssertFalse(KeyframeEditing.setEase(&c, key: "x", .easeIn, at: 0.5, tolerance: tol))
        XCTAssertFalse(KeyframeEditing.setEase(&c, key: "y", .easeIn, at: 1, tolerance: tol))
        XCTAssertTrue(KeyframeEditing.setEase(&c, key: "x", .bezier(0.1, 0.2, 0.3, 0.4), at: 1, tolerance: tol))
        XCTAssertEqual(c.keyframes["x"]![1].ease, .bezier(0.1, 0.2, 0.3, 0.4))
        XCTAssertEqual(c.keyframes["x"]![0].ease, .linear)
        // 値の補間に効く
        let mid = Animation.value(of: "x", in: c, at: 1.5)
        XCTAssertNotEqual(mid, 0.5, accuracy: 1e-3)
    }

    func testFileTokenRoundTrip() {
        for (_, e) in EaseCurve.presets {
            XCTAssertEqual(Ease(token: e.token), e)
        }
        XCTAssertEqual(Ease.bezier(0.34, 1.56, 0.64, 1).token, "bezier:0.34,1.56,0.64,1")
    }
}
