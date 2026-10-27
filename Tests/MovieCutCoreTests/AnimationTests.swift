import XCTest
@testable import MovieCutCore

final class AnimationTests: XCTestCase {
    // MARK: イージング

    func testEaseEndpointsAreExact() {
        let all: [Ease] = [.linear, .easeIn, .easeOut, .easeInOut, .hold, .bezier(0.25, 0.1, 0.25, 1), .bezier(0.1, -0.5, 0.9, 1.5)]
        for e in all {
            XCTAssertEqual(e.apply(0), 0, "\(e)")
            XCTAssertEqual(e.apply(1), 1, "\(e)")
            XCTAssertEqual(e.apply(-3), 0, "\(e)")
            XCTAssertEqual(e.apply(7), 1, "\(e)")
            XCTAssertEqual(e.apply(.nan), 0, "\(e)")
        }
    }

    func testStandardEasesAreMonotonic() {
        for e in [Ease.linear, .easeIn, .easeOut, .easeInOut, .bezier(0.25, 0.1, 0.25, 1), .bezier(0.42, 0, 0.58, 1)] {
            var prev = -1.0
            for i in 0...1000 {
                let v = e.apply(Double(i) / 1000)
                XCTAssertGreaterThanOrEqual(v, prev - 1e-12, "\(e) at \(i)")
                prev = v
            }
        }
    }

    func testEaseShapes() {
        XCTAssertLessThan(Ease.easeIn.apply(0.5), 0.5)          // ゆっくり始まる
        XCTAssertGreaterThan(Ease.easeOut.apply(0.5), 0.5)      // ゆっくり終わる
        XCTAssertEqual(Ease.easeInOut.apply(0.5), 0.5, accuracy: 1e-6)
        XCTAssertEqual(Ease.easeInOut.apply(0.25) + Ease.easeInOut.apply(0.75), 1, accuracy: 1e-6)   // 点対称
        XCTAssertEqual(Ease.hold.apply(0.999), 0)
        XCTAssertEqual(Ease.hold.apply(1), 1)
    }

    /// 二分法で独立に解いた値と比べる(CSS cubic-bezier と同じ式)。
    func testBezierSolverAccuracy() {
        func reference(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ x: Double) -> Double {
            func b(_ a: Double, _ c: Double, _ s: Double) -> Double { let m = 1 - s; return 3 * m * m * s * a + 3 * m * s * s * c + s * s * s }
            var lo = 0.0, hi = 1.0
            for _ in 0..<200 { let mid = (lo + hi) / 2; if b(x1, x2, mid) < x { lo = mid } else { hi = mid } }
            return b(y1, y2, (lo + hi) / 2)
        }
        let curves: [(Double, Double, Double, Double)] = [(0.25, 0.1, 0.25, 1), (0.42, 0, 0.58, 1), (0, 0, 1, 1), (0.9, 0, 0.1, 1), (0.05, 0.9, 0.95, 0.1), (0.17, 0.67, 0.83, 0.67), (0.3, -0.6, 0.7, 1.6)]
        for c in curves {
            for i in 1..<200 {
                let x = Double(i) / 200
                XCTAssertEqual(Ease.cubicBezier(c.0, c.1, c.2, c.3, x), reference(c.0, c.1, c.2, c.3, x), accuracy: 1e-6, "\(c) x=\(x)")
            }
        }
        // (0,0,1,1) は直線
        XCTAssertEqual(Ease.cubicBezier(0, 0, 1, 1, 0.37), 0.37, accuracy: 1e-7)
    }

    func testBezierCanOvershoot() {
        let e = Ease.bezier(0.3, -0.6, 0.7, 1.6)
        XCTAssertLessThan((1...200).map { e.apply(Double($0) / 400) }.min()!, 0)     // 前半で一度戻る
        XCTAssertGreaterThan((200...399).map { e.apply(Double($0) / 400) }.max()!, 1)  // 後半で行き過ぎる
    }

    func testEaseTokens() throws {
        for e: Ease in [.linear, .easeIn, .easeOut, .easeInOut, .hold, .bezier(0.25, 0.1, 0.25, 1), .bezier(0.123456789, -0.4, 0.5, 1.7)] {
            XCTAssertEqual(Ease(token: e.token), e)
            let data = try JSONEncoder().encode([e])
            XCTAssertEqual(try JSONDecoder().decode([Ease].self, from: data), [e])
        }
        XCTAssertEqual(Ease.bezier(0.25, 0.1, 0.25, 1).token, "bezier:0.25,0.1,0.25,1")
        XCTAssertNil(Ease(token: "wobble"))
        XCTAssertNil(Ease(token: "bezier:1,2,3"))
        XCTAssertNil(Ease(token: "bezier:a,b,c,d"))
        // x 側の制御点は 0〜1 に収める
        XCTAssertEqual(Ease(token: "bezier:2,0,-1,1"), .bezier(1, 0, 0, 1))
        // 読めない文字列・数値は linear
        XCTAssertEqual(try JSONDecoder().decode([Ease].self, from: Data(#"["bogus", 5, null]"#.utf8)), [.linear, .linear, .linear])
    }

    // MARK: 評価

    private func ks(_ pairs: [(Double, Double)], ease: Ease = .linear) -> [Keyframe] { pairs.map { Keyframe(t: $0.0, v: $0.1, ease: ease) } }

    func testInterpolateEdgeCases() {
        XCTAssertNil(Animation.interpolate([], at: 1))
        XCTAssertEqual(Animation.interpolate(ks([(2, 7)]), at: -5), 7)        // キー 1 つ = 一定
        XCTAssertEqual(Animation.interpolate(ks([(2, 7)]), at: 99), 7)
        let two = ks([(1, 10), (3, 20)])
        XCTAssertEqual(Animation.interpolate(two, at: 0), 10)                 // 最初より前は最初の値
        XCTAssertEqual(Animation.interpolate(two, at: 1), 10)
        XCTAssertEqual(Animation.interpolate(two, at: 2), 15)
        XCTAssertEqual(Animation.interpolate(two, at: 3), 20)
        XCTAssertEqual(Animation.interpolate(two, at: 50), 20)                // 最後より後は最後の値
    }

    func testInterpolateMultipleSegmentsUseEachSegmentsEase() {
        let k = [Keyframe(t: 0, v: 0, ease: .linear), Keyframe(t: 2, v: 10, ease: .hold), Keyframe(t: 4, v: 30, ease: .linear), Keyframe(t: 6, v: 0)]
        XCTAssertEqual(Animation.interpolate(k, at: 1)!, 5, accuracy: 1e-9)    // 直線
        XCTAssertEqual(Animation.interpolate(k, at: 3)!, 10, accuracy: 1e-9)   // 階段: 次のキーまで 10 のまま
        XCTAssertEqual(Animation.interpolate(k, at: 3.999)!, 10, accuracy: 1e-9)
        XCTAssertEqual(Animation.interpolate(k, at: 4)!, 30, accuracy: 1e-9)
        XCTAssertEqual(Animation.interpolate(k, at: 5)!, 15, accuracy: 1e-9)
    }

    func testInterpolateEaseApplied() {
        let k = [Keyframe(t: 0, v: 0, ease: .easeIn), Keyframe(t: 1, v: 100)]
        XCTAssertEqual(Animation.interpolate(k, at: 0.5)!, 100 * Ease.easeIn.apply(0.5), accuracy: 1e-9)
        XCTAssertLessThan(Animation.interpolate(k, at: 0.5)!, 50)
    }

    func testUnsortedAndDuplicateInput() {
        let messy = [Keyframe(t: 3, v: 30), Keyframe(t: 1, v: 10), Keyframe(t: 2, v: 99), Keyframe(t: 2, v: 20)]   // 2 秒が重複(後が勝つ)
        XCTAssertEqual(Animation.normalized(messy).map(\.t), [1, 2, 3])
        XCTAssertEqual(Animation.normalized(messy).map(\.v), [10, 20, 30])
        XCTAssertEqual(Animation.interpolate(messy, at: 1.5)!, 15, accuracy: 1e-9)
        XCTAssertEqual(Animation.interpolate(messy, at: 2.5)!, 25, accuracy: 1e-9)
        XCTAssertEqual(Animation.interpolate(messy, at: 0)!, 10)
        // NaN は捨てる
        XCTAssertEqual(Animation.normalized([Keyframe(t: .nan, v: 1), Keyframe(t: 1, v: 2)]).count, 1)
    }

    func testClipValueStaticAndAnimated() {
        var c = Clip(); c.type = .image; c.start = 10; c.duration = 4
        XCTAssertEqual(Animation.value(of: "x", in: c, at: 1), 0.5)            // 未設定は既定
        XCTAssertEqual(Animation.value(of: "rotation", in: c, at: 1), 0)
        XCTAssertEqual(Animation.value(of: "scale", in: c, at: 1), 1)
        c.x = 0.2
        XCTAssertEqual(Animation.value(of: "x", in: c, at: 1), 0.2)
        XCTAssertFalse(Animation.isAnimated("x", in: c))
        c.keyframes["x"] = ks([(0, 0), (2, 1)])
        XCTAssertTrue(Animation.isAnimated("x", in: c))
        XCTAssertFalse(Animation.isAnimated("y", in: c))
        XCTAssertEqual(Animation.value(of: "x", in: c, at: 1), 0.5, accuracy: 1e-9)
        XCTAssertEqual(c.value(of: "x", atProjectTime: 11), 0.5, accuracy: 1e-9)      // プロジェクトの時刻 = 頭 + 1 秒
        XCTAssertEqual(Animation.value(of: "y", in: c, at: 1), 0.5)                  // 他の項目は設定値のまま
        c.keyframes["x"] = []
        XCTAssertFalse(Animation.isAnimated("x", in: c))
        XCTAssertEqual(Animation.value(of: "x", in: c, at: 1), 0.2)
    }

    func testKeysPerClipType() {
        var c = Clip()
        c.type = .blur
        XCTAssertEqual(Animation.keys(for: c), ["x", "y", "w", "h", "strength"])
        c.type = .image
        XCTAssertEqual(Animation.keys(for: c), ["x", "y", "scale", "rotation", "opacity", "blur"])
        c.type = .audio
        XCTAssertEqual(Animation.keys(for: c), ["volume"])      // 音声は音量だけ動かせる(A-5)
        c.type = .text
        XCTAssertFalse(Animation.keys(for: c).contains("volume"))
    }

    func testShiftSplitHelpers() {
        let k: [String: [Keyframe]] = ["x": ks([(0, 0), (2, 10), (4, 0)])]
        XCTAssertEqual(Animation.shifted(k, by: -1)["x"]!.map(\.t), [-1, 1, 3])
        let (l, r) = Animation.split(k, at: 1)
        XCTAssertEqual(l["x"]!.map(\.t), [0, 1]); XCTAssertEqual(l["x"]!.map(\.v), [0, 5])        // 左: 境目に補間値
        XCTAssertEqual(r["x"]!.map(\.t), [0, 1, 3]); XCTAssertEqual(r["x"]!.map(\.v), [5, 10, 0]) // 右: 境目 + ずらしたキー
        // 値が連続
        XCTAssertEqual(Animation.interpolate(l["x"]!, at: 1)!, Animation.interpolate(r["x"]!, at: 0)!, accuracy: 1e-12)
        // 切れ目がキーの上: 境目を足さない
        let (l2, r2) = Animation.split(k, at: 2)
        XCTAssertEqual(l2["x"]!.map(\.t), [0, 2]); XCTAssertEqual(r2["x"]!.map(\.t), [0, 2])
        // 全部のキーより後ろで切る: 左はそのまま、右は最後の値で一定
        let (l3, r3) = Animation.split(k, at: 9)
        XCTAssertEqual(l3["x"]!.count, 3); XCTAssertEqual(r3["x"]!, [Keyframe(t: 0, v: 0)])
        // 全部のキーより前で切る: 左は最初の値で一定、右はそのまま(境目は同じ値)
        let (l4, r4) = Animation.split(k, at: 0)
        XCTAssertFalse(l4["x"]!.isEmpty); XCTAssertEqual(r4["x"]!.first!.v, 0)
        // 階段のキーは階段のまま分かれる
        let h: [String: [Keyframe]] = ["x": [Keyframe(t: 0, v: 0, ease: .hold), Keyframe(t: 4, v: 8)]]
        let (hl, hr) = Animation.split(h, at: 1)
        XCTAssertEqual(Animation.interpolate(hl["x"]!, at: 1)!, 0)
        XCTAssertEqual(Animation.interpolate(hr["x"]!, at: 2.9)!, 0)       // 元の 3.9 秒
        XCTAssertEqual(Animation.interpolate(hr["x"]!, at: 3)!, 8)         // 元の 4 秒
        XCTAssertEqual(Animation.allKeyTimes(["a": ks([(0, 0), (1, 0)]), "b": ks([(1, 0), (2, 0)])]), [0, 1, 2])
    }
}
