import XCTest
@testable import MovieCutCore

/// 第2波バッチC: ルール画像ワイプ(#60)と登場/退場プリセット(#61)の純粋計算のテスト。
final class RuleWipeMathTests: XCTestCase {
    func testFieldIsAlwaysInUnitRange() {
        for kind in RuleWipeKind.allCases {
            for i in 0...20 {
                for j in 0...20 {
                    let v = RuleWipeMath.field(kind, x: Double(i) / 20, y: Double(j) / 20, aspect: 16.0 / 9.0)
                    XCTAssertGreaterThanOrEqual(v, 0, "\(kind) (\(i),\(j))")
                    XCTAssertLessThanOrEqual(v, 1, "\(kind) (\(i),\(j))")
                }
            }
        }
    }

    func testFieldDirections() {
        // 横: 左が 0、右が 1。縦: 上が 0、下が 1
        XCTAssertEqual(RuleWipeMath.field(.horizontal, x: 0, y: 0.5), 0, accuracy: 1e-12)
        XCTAssertEqual(RuleWipeMath.field(.horizontal, x: 1, y: 0.5), 1, accuracy: 1e-12)
        XCTAssertEqual(RuleWipeMath.field(.vertical, x: 0.5, y: 0), 0, accuracy: 1e-12)
        XCTAssertEqual(RuleWipeMath.field(.vertical, x: 0.5, y: 1), 1, accuracy: 1e-12)
        // 円・四角・菱形: 中心が 0
        for k in [RuleWipeKind.circle, .square, .diamond] {
            XCTAssertEqual(RuleWipeMath.field(k, x: 0.5, y: 0.5, aspect: 1), 0, accuracy: 1e-12, "\(k)")
        }
        // 時計回り: 12 時方向が 0、3 時方向が 1/4、6 時方向が 1/2
        XCTAssertEqual(RuleWipeMath.field(.clock, x: 0.5, y: 0.1, aspect: 1), 0, accuracy: 1e-9)
        XCTAssertEqual(RuleWipeMath.field(.clock, x: 0.9, y: 0.5, aspect: 1), 0.25, accuracy: 1e-9)
        XCTAssertEqual(RuleWipeMath.field(.clock, x: 0.5, y: 0.9, aspect: 1), 0.5, accuracy: 1e-9)
        XCTAssertEqual(RuleWipeMath.field(.clock, x: 0.1, y: 0.5, aspect: 1), 0.75, accuracy: 1e-9)
    }

    func testAlphaEndpointsAndHardEdge() {
        XCTAssertEqual(RuleWipeMath.alpha(field: 0, progress: 0, softness: 0.06), 0, accuracy: 1e-12)
        XCTAssertEqual(RuleWipeMath.alpha(field: 1, progress: 1, softness: 0.06), 1, accuracy: 1e-12)
        XCTAssertEqual(RuleWipeMath.alpha(field: 0.5, progress: 0.5, softness: 0), 1)
        XCTAssertEqual(RuleWipeMath.alpha(field: 0.6, progress: 0.5, softness: 0), 0)
        XCTAssertEqual(RuleWipeMath.alpha(field: 0.4, progress: 0.5, softness: 0), 1)
        // やわらかさ: 境界の内側は半分、外れるほど 0/1 に近づく
        let mid = RuleWipeMath.alpha(field: 0.5, progress: 0.5, softness: 0.2)
        XCTAssertGreaterThan(mid, 0.3); XCTAssertLessThan(mid, 0.7)
        XCTAssertEqual(RuleWipeMath.alpha(field: 0, progress: 0.5, softness: 0.2), 1, accuracy: 1e-12)
        XCTAssertEqual(RuleWipeMath.alpha(field: 1, progress: 0.5, softness: 0.2), 0, accuracy: 1e-12)
        // 壊れたやわらかさは既定に倒す
        XCTAssertEqual(RuleWipeMath.clampedSoftness(.nan), RuleWipeMath.defaultSoftness)
        XCTAssertEqual(RuleWipeMath.clampedSoftness(99), RuleWipeMath.maxSoftness)
        XCTAssertEqual(RuleWipeMath.clampedSoftness(-1), 0)
    }

    func testVisibleFractionGrowsWithProgress() {
        for kind in RuleWipeKind.allCases {
            XCTAssertLessThan(RuleWipeMath.visibleFraction(kind, progress: 0, softness: 0, samples: 32), 0.05, "\(kind) 開始")
            XCTAssertEqual(RuleWipeMath.visibleFraction(kind, progress: 1, softness: 0, samples: 32), 1, accuracy: 0.02, "\(kind) 完了")
            let a = RuleWipeMath.visibleFraction(kind, progress: 0.25, softness: 0, samples: 32)
            let b = RuleWipeMath.visibleFraction(kind, progress: 0.5, softness: 0, samples: 32)
            let c = RuleWipeMath.visibleFraction(kind, progress: 0.75, softness: 0, samples: 32)
            XCTAssertLessThan(a, b, "\(kind)"); XCTAssertLessThan(b, c, "\(kind)")
        }
        // 横(線形)は面積率 ≒ 進行度
        XCTAssertEqual(RuleWipeMath.visibleFraction(.horizontal, progress: 0.5, softness: 0, samples: 64), 0.5, accuracy: 0.03)
        XCTAssertEqual(RuleWipeMath.visibleFraction(.vertical, progress: 0.3, softness: 0, samples: 64), 0.3, accuracy: 0.03)
        // 散らばり(ハッシュ順)も半分でだいたい半分
        let s = RuleWipeMath.visibleFraction(.scatter, progress: 0.5, softness: 0, samples: 60)
        XCTAssertGreaterThan(s, 0.3); XCTAssertLessThan(s, 0.7)
    }

    func testGrayscaleAndMaskPixels() {
        let g = RuleWipeMath.grayscalePixels(.horizontal, width: 4, height: 1)
        XCTAssertEqual(g.count, 4)
        XCTAssertTrue(g[0] < g[1] && g[1] < g[2] && g[2] < g[3])
        XCTAssertEqual(RuleWipeMath.grayscalePixels(.horizontal, width: 0, height: 4), [])
        // カスタム値列: 全部 0.5 なら、進行度が 0.5 を境に見える/見えない
        let field = [Double](repeating: 0.5, count: 6)
        XCTAssertEqual(RuleWipeMath.maskPixels(field: field, width: 3, height: 2, progress: 0.4, softness: 0), [0, 0, 0, 0, 0, 0])
        XCTAssertEqual(RuleWipeMath.maskPixels(field: field, width: 3, height: 2, progress: 0.6, softness: 0), [255, 255, 255, 255, 255, 255])
        XCTAssertEqual(RuleWipeMath.maskPixels(field: [0.5], width: 3, height: 2, progress: 0.6, softness: 0), [])  // 大きさ不一致は空
        XCTAssertEqual(RuleWipeMath.fieldFromLuminance([0, 128, 255]), [0, 128.0 / 255, 1])
        // 内蔵マスク: 横ルール半分では左半分だけ不透明
        let m = RuleWipeMath.maskPixels(.horizontal, progress: 0.5, softness: 0, width: 8, height: 2)
        XCTAssertEqual(Array(m[0..<4]), [255, 255, 255, 255])
        XCTAssertEqual(Array(m[4..<8]), [0, 0, 0, 0])
    }

    func testFeatherMath() {
        XCTAssertEqual(FeatherMath.alpha(x: 0.5, y: 0.5, feather: 0.3), 1, accuracy: 1e-12)   // 内側
        XCTAssertEqual(FeatherMath.alpha(x: 0, y: 0.5, feather: 0.3), 0, accuracy: 1e-12)     // 縁
        XCTAssertEqual(FeatherMath.alpha(x: 0.15, y: 0.5, feather: 0.3), 0.5, accuracy: 1e-12) // 帯の半分
        XCTAssertEqual(FeatherMath.alpha(x: 0, y: 0, feather: 0), 1, accuracy: 1e-12)          // 帯なしは全部見える
        let px = FeatherMath.maskPixels(feather: 0.25, width: 8, height: 8)
        XCTAssertEqual(px.count, 64)
        XCTAssertEqual(px[0], 64)                      // 角の画素(中心が帯の 1/4 の位置)は薄い
        XCTAssertEqual(px[3 * 8 + 3], 255)             // 内側は不透明
    }
}

final class TransitionPresetStateTests: XCTestCase {
    func state(_ k: TransitionKind, _ u: Double, edge: TransitionEdge = .in, size: (w: Double, h: Double) = (0.5, 0.5)) -> TransitionState {
        TransitionMath.state(kind: k, edge: edge, u: u, center: (0.5, 0.5), size: size)
    }

    func testRuleWipeStates() {
        XCTAssertEqual(state(.ruleHorizontal, 0.5).mask, .ruleImage("horizontal", 0.5, RuleWipeMath.defaultSoftness, nil))
        XCTAssertEqual(state(.ruleSpiral, 0.25).mask, .ruleImage("spiral", 0.25, RuleWipeMath.defaultSoftness, nil))
        XCTAssertTrue(state(.ruleCircle, 0).mask?.isEmpty ?? false)
        XCTAssertFalse(state(.ruleCircle, 0.5).isIdentity)
        // カスタム: 素材の場所がマスクに乗る
        let custom = TransitionMath.state(kind: .ruleCustom, edge: .in, u: 0.5, softness: 0.1, ruleSource: "/tmp/rule.png")
        XCTAssertEqual(custom.mask, .ruleImage("custom", 0.5, 0.1, "/tmp/rule.png"))
        // やわらかさの引き渡し
        let soft = TransitionMath.state(kind: .ruleVertical, edge: .out, u: 0.3, softness: 0.2)
        XCTAssertEqual(soft.mask, .ruleImage("vertical", 0.3, 0.2, nil))
    }

    func testReleaseStates() {
        // モザイク解除: 頭で最大、終わりで消える。不透明度は変えない
        XCTAssertEqual(state(.mosaicRelease, 0).pixelateAdd, 64, accuracy: 1e-9)
        XCTAssertEqual(state(.mosaicRelease, 0.5).pixelateAdd, 32, accuracy: 1e-9)
        XCTAssertEqual(state(.mosaicRelease, 0.5).opacityMul, 1, accuracy: 1e-12)
        XCTAssertTrue(state(.mosaicRelease, 1).isIdentity)
        // ぼかし解除: ぼかしだけ(フェードしない)。従来の blur はフェードもする
        XCTAssertEqual(state(.blurRelease, 0).blurAdd, 60, accuracy: 1e-9)
        XCTAssertEqual(state(.blurRelease, 0).opacityMul, 1, accuracy: 1e-12)
        XCTAssertEqual(state(.blur, 0).opacityMul, 0, accuracy: 1e-12)
        // 境界ぼかし解除: ぼかし + 縁の帯
        let e = state(.edgeBlurRelease, 0)
        XCTAssertEqual(e.blurAdd, 40, accuracy: 1e-9)
        XCTAssertEqual(e.feather, 0.35, accuracy: 1e-9)
        XCTAssertTrue(state(.edgeBlurRelease, 1).isIdentity)
    }

    func testMotionPresetStates() {
        // 傾斜変形: 登場は -35°、退場は +35° から
        XCTAssertEqual(state(.skewIn, 0).skewXAdd, -35, accuracy: 1e-9)
        XCTAssertEqual(state(.skewIn, 0, edge: .out).skewXAdd, 35, accuracy: 1e-9)
        XCTAssertTrue(state(.skewIn, 0).movesGeometry)
        // 砕け散り: 散らばりマスク + 回転 + 縮小
        let sh = state(.shatter, 0)
        XCTAssertEqual(sh.mask, .ruleImage("scatter", 0, 0, nil))
        XCTAssertEqual(sh.scaleMul, 0.92, accuracy: 1e-9)
        XCTAssertEqual(sh.rotationAdd, -6, accuracy: 1e-9)
        // 跳ね: 頭は下に 0.45、終わりは 0。途中で跳ねる(単調ではない)
        XCTAssertEqual(state(.bounceIn, 0).offsetY, 0.45, accuracy: 1e-9)
        XCTAssertTrue(state(.bounceIn, 1).isIdentity)
        XCTAssertEqual(TransitionMath.easeOutBounce(0), 0, accuracy: 1e-12)
        XCTAssertEqual(TransitionMath.easeOutBounce(1), 1, accuracy: 1e-12)
        XCTAssertLessThan(state(.bounceIn, 0.5).offsetY, state(.bounceIn, 0.25).offsetY)
        // 起き上がり
        let r = state(.riseIn, 0)
        XCTAssertEqual(r.rotationAdd, -75, accuracy: 1e-9)
        XCTAssertEqual(r.offsetY, 0.18, accuracy: 1e-9)
        XCTAssertEqual(state(.riseIn, 0, edge: .out).rotationAdd, 75, accuracy: 1e-9)
        // ポップ: 途中で 1 を超える
        XCTAssertGreaterThan(TransitionMath.easeOutBack(0.7), 1)
        XCTAssertEqual(TransitionMath.easeOutBack(0), 0, accuracy: 1e-9)
        XCTAssertEqual(TransitionMath.easeOutBack(1), 1, accuracy: 1e-9)
        XCTAssertGreaterThan(state(.pop, 0.7).scaleMul, 1)
        XCTAssertEqual(state(.pop, 0).opacityMul, 0, accuracy: 1e-12)
        // フェードズーム
        XCTAssertEqual(state(.fadeZoom, 0).scaleMul, 0.9, accuracy: 1e-9)
        XCTAssertEqual(state(.fadeZoom, 0.5).opacityMul, 0.5, accuracy: 1e-9)
    }

    func testRegionAndDriftStates() {
        // 領域外: 自分の枠 + 余白ぶんだけ外
        XCTAssertEqual(state(.regionLeft, 0).offsetX, -0.52, accuracy: 1e-9)
        XCTAssertEqual(state(.regionRight, 0).offsetX, 0.52, accuracy: 1e-9)
        XCTAssertEqual(state(.regionUp, 0).offsetY, -0.52, accuracy: 1e-9)
        XCTAssertEqual(state(.regionDown, 0, size: (0.2, 0.2)).offsetY, 0.22, accuracy: 1e-9)
        XCTAssertTrue(state(.regionLeft, 1).isIdentity)
        // 移動フェード: 0.25 の移動 + フェード
        XCTAssertEqual(state(.driftLeft, 0).offsetX, -0.25, accuracy: 1e-9)
        XCTAssertEqual(state(.driftDown, 0).offsetY, 0.25, accuracy: 1e-9)
        XCTAssertEqual(state(.driftUp, 0.5).opacityMul, 0.5, accuracy: 1e-9)
        // 種類の分類
        XCTAssertTrue(TransitionKind.regionLeft.needsSize)
        XCTAssertFalse(TransitionKind.driftLeft.needsSize)
        XCTAssertEqual(TransitionKind.ruleChecker.category, .ruleWipe)
        XCTAssertEqual(TransitionKind.shatter.category, .effect)
        XCTAssertEqual(TransitionKind.allCases.filter { $0.category == .ruleWipe }.count, 12)
        for k in TransitionKind.allCases {
            XCTAssertFalse(k.label.isEmpty, "\(k)")
            XCTAssertNotEqual(k.label, k.rawValue, "\(k)")
        }
    }

    func testCombinedTakesMaxForPixelateAndFeather() {
        var a = TransitionState(); a.pixelateAdd = 30; a.feather = 0.1
        var b = TransitionState(); b.pixelateAdd = 50; b.feather = 0.05
        let c = a.combined(with: b)
        XCTAssertEqual(c.pixelateAdd, 50)
        XCTAssertEqual(c.feather, 0.1)
    }

    func testParamsAccessors() {
        var tr = Transition(.ruleHorizontal)
        XCTAssertEqual(tr.ruleSoftness, RuleWipeMath.defaultSoftness)
        XCTAssertNil(tr.ruleSource)
        tr.params = .object(["softness": .number(0.2), "ruleSrc": .string("/a/b.png")])
        XCTAssertEqual(tr.ruleSoftness, 0.2, accuracy: 1e-12)
        XCTAssertEqual(tr.ruleSource, "/a/b.png")
        tr.params = .object(["softness": .number(99)])
        XCTAssertEqual(tr.ruleSoftness, RuleWipeMath.maxSoftness)   // 範囲に収める
        tr.params = .object(["ruleSrc": .string("")])
        XCTAssertNil(tr.ruleSource)                                  // 空は無し
    }

    func testNewKindsRoundTripThroughJSON() throws {
        for k in TransitionKind.allCases {
            let tr = Transition(k, duration: 0.7)
            let data = try JSONEncoder().encode(tr)
            let back = try JSONDecoder().decode(Transition.self, from: data)
            XCTAssertEqual(back, tr, "\(k)")
            XCTAssertEqual(back.known, k, "\(k)")
        }
        // params 付きも往復する
        var tr = Transition(.ruleCustom, duration: 1)
        tr.params = .object(["softness": .number(0.12), "ruleSrc": .string("/x.png")])
        let back = try JSONDecoder().decode(Transition.self, from: JSONEncoder().encode(tr))
        XCTAssertEqual(back, tr)
        XCTAssertEqual(back.ruleSource, "/x.png")
    }

    func testRuleEditing() {
        var c = Clip(); c.type = .image; c.duration = 4
        c.transitionIn = Transition(.ruleHorizontal, duration: 1)
        XCTAssertTrue(TransitionEditing.setRuleSoftness(&c, edge: .in, 0.2))
        XCTAssertEqual(c.transitionIn?.ruleSoftness ?? 0, 0.2, accuracy: 1e-9)
        XCTAssertFalse(TransitionEditing.setRuleSoftness(&c, edge: .in, 0.2))   // 同じ値は変えない
        XCTAssertTrue(TransitionEditing.setRuleSoftness(&c, edge: .in, RuleWipeMath.defaultSoftness))
        XCTAssertNil(c.transitionIn?.params)                                    // 既定に戻すと params は消える
        // ルール以外には効かない
        c.transitionIn = Transition(.fade, duration: 1)
        XCTAssertFalse(TransitionEditing.setRuleSoftness(&c, edge: .in, 0.2))
        // カスタム画像の場所は ruleCustom だけ
        c.transitionIn = Transition(.ruleCustom, duration: 1)
        XCTAssertTrue(TransitionEditing.setRuleSource(&c, edge: .in, "/tmp/r.png"))
        XCTAssertEqual(c.transitionIn?.ruleSource, "/tmp/r.png")
        XCTAssertTrue(TransitionEditing.setRuleSource(&c, edge: .in, nil))
        XCTAssertNil(c.transitionIn?.params)
        c.transitionIn = Transition(.ruleCircle, duration: 1)
        XCTAssertFalse(TransitionEditing.setRuleSource(&c, edge: .in, "/tmp/r.png"))
    }
}

final class EntrancePresetTests: XCTestCase {
    func imgClip(duration: Double = 4) -> Clip {
        var c = Clip(); c.type = .image; c.start = 0; c.duration = duration; c.x = 0.5; c.y = 0.5; c.scale = 1; c.opacity = 1
        return c
    }

    func testCatalogIsConsistent() {
        let ids = EntrancePresets.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "id の重複")
        for p in EntrancePresets.all {
            XCTAssertGreaterThan(p.durationIn, 0, p.id); XCTAssertLessThanOrEqual(p.durationIn, 5, p.id)
            XCTAssertGreaterThan(p.durationOut, 0, p.id); XCTAssertLessThanOrEqual(p.durationOut, 5, p.id)
            XCTAssertFalse(p.label.isEmpty, p.id)
            XCTAssertEqual(EntrancePresets.preset(id: p.id), p)
        }
        // YMM4 で名前が確認されているプリセットが揃っている
        for id in ["fade", "screenLeft", "regionLeft", "driftLeft", "zoom", "spin", "blurRelease", "mosaicRelease",
                   "edgeBlurRelease", "skewIn", "shatter", "bounceIn", "riseIn", "bubbleFade",
                   "ruleHorizontal", "ruleVertical", "ruleCircle", "ruleSquare", "ruleClock"] {
            XCTAssertNotNil(EntrancePresets.preset(id: id), id)
        }
    }

    func testApplySetsTransition() {
        var c = imgClip()
        let p = EntrancePresets.preset(id: "mosaicRelease")!
        XCTAssertTrue(EntrancePresets.apply(p, edge: .in, to: &c))
        XCTAssertEqual(c.transitionIn?.known, .mosaicRelease)
        XCTAssertEqual(c.transitionIn?.duration ?? 0, p.durationIn, accuracy: 1e-9)
        XCTAssertEqual(c.transitionIn?.ease, p.easeIn)
        XCTAssertFalse(EntrancePresets.apply(p, edge: .in, to: &c))   // 同じ適用は変えない
        XCTAssertTrue(EntrancePresets.apply(p, edge: .out, to: &c))
        XCTAssertEqual(c.transitionOut?.ease, p.easeOut)
        // 長さ指定と、短いクリップでの丸め
        var short = imgClip(duration: 0.6)
        XCTAssertTrue(EntrancePresets.apply(p, edge: .in, to: &short, duration: 5))
        XCTAssertEqual(short.transitionIn?.duration ?? 0, 0.3, accuracy: 1e-9)   // 半分まで
        // 音声クリップには付けられない
        var a = Clip(); a.type = .audio; a.duration = 4
        XCTAssertFalse(EntrancePresets.apply(p, edge: .in, to: &a))
    }

    func testKeyframeGenerationValidity() {
        let c = imgClip()
        for p in EntrancePresets.all {
            let ksIn = EntrancePresets.keyframes(p, edge: .in, clip: c, size: (0.5, 0.5))
            XCTAssertEqual(ksIn != nil, p.supportsKeyframes, "\(p.id) の変換可否")
            guard let ks = ksIn else { continue }
            for (key, list) in ks {
                XCTAssertFalse(list.isEmpty, "\(p.id) \(key)")
                // 時刻は昇順・範囲内、値は項目の範囲内
                for i in list.indices {
                    XCTAssertGreaterThanOrEqual(list[i].t, 0, "\(p.id) \(key)")
                    XCTAssertLessThanOrEqual(list[i].t, c.duration, "\(p.id) \(key)")
                    if i > 0 { XCTAssertGreaterThan(list[i].t, list[i - 1].t, "\(p.id) \(key)") }
                    let r = Animation.range(of: key, type: c.type)
                    XCTAssertTrue(r.contains(list[i].v), "\(p.id) \(key) 値 \(list[i].v) が範囲外")
                }
                // 終端の値はクリップの設定値に一致する(登場は最後、退場は最初)
                let base = Animation.value(of: key, in: c, at: 0)
                XCTAssertEqual(list.last!.v, base, accuracy: 1e-9, "\(p.id) \(key) 終端")
                // 評価しても端では設定値どおり
                XCTAssertEqual(Animation.interpolate(list, at: list.last!.t) ?? .nan, base, accuracy: 1e-9, "\(p.id) \(key)")
            }
        }
    }

    func testKeyframeStartValues() {
        let c = imgClip()
        // フェード: 不透明度 0 → 1
        let fade = EntrancePresets.keyframes(EntrancePresets.preset(id: "fade")!, edge: .in, clip: c)!
        XCTAssertEqual(fade["opacity"]!.first!.v, 0, accuracy: 1e-9)
        XCTAssertEqual(fade["opacity"]!.last!.v, 1, accuracy: 1e-9)
        // 画面外(左): 枠 0.5 なら x は -0.25 から
        let slide = EntrancePresets.keyframes(EntrancePresets.preset(id: "screenLeft")!, edge: .in, clip: c, size: (0.5, 0.5))!
        XCTAssertEqual(slide["x"]!.first!.v, -0.25, accuracy: 1e-9)
        XCTAssertEqual(slide["x"]!.last!.v, 0.5, accuracy: 1e-9)
        // 領域外(左): 現在位置 - (枠 + 0.02)
        let region = EntrancePresets.keyframes(EntrancePresets.preset(id: "regionLeft")!, edge: .in, clip: c, size: (0.5, 0.5))!
        XCTAssertEqual(region["x"]!.first!.v, 0.5 - 0.52, accuracy: 1e-9)
        // 退場は逆: 最初が設定値、最後が消える値
        let out = EntrancePresets.keyframes(EntrancePresets.preset(id: "fade")!, edge: .out, clip: c)!
        XCTAssertEqual(out["opacity"]!.first!.v, 1, accuracy: 1e-9)
        XCTAssertEqual(out["opacity"]!.last!.v, 0, accuracy: 1e-9)
        XCTAssertEqual(out["opacity"]!.first!.t, c.duration - 0.5, accuracy: 1e-9)
        // 跳ね: 最初は +0.45 下、最後は設定値
        let bounce = EntrancePresets.keyframes(EntrancePresets.preset(id: "bounceIn")!, edge: .in, clip: c)!
        XCTAssertEqual(bounce["y"]!.first!.v, 0.95, accuracy: 1e-9)
        XCTAssertEqual(bounce["y"]!.last!.v, 0.5, accuracy: 1e-9)
        // 変換できない種類
        for id in ["mosaicRelease", "edgeBlurRelease", "skewIn", "shatter", "ruleCircle"] {
            XCTAssertNil(EntrancePresets.keyframes(EntrancePresets.preset(id: id)!, edge: .in, clip: c), id)
        }
    }

    func testApplyAsKeyframes() {
        var c = imgClip()
        XCTAssertTrue(EntrancePresets.applyAsKeyframes(EntrancePresets.preset(id: "screenLeft")!, edge: .in, to: &c, size: (0.5, 0.5)))
        XCTAssertEqual(Animation.value(of: "x", in: c, at: 0), -0.25, accuracy: 1e-9)
        XCTAssertEqual(Animation.value(of: "x", in: c, at: 2), 0.5, accuracy: 1e-9)
        XCTAssertFalse(EntrancePresets.applyAsKeyframes(EntrancePresets.preset(id: "shatter")!, edge: .in, to: &c))
    }
}


// MARK: - バグ確認 第2部 C19: 硬いワイプの開始と、境界ぼかしの帯幅

final class RuleWipeBoundaryTests: XCTestCase {
    func testHardWipeShowsNothingAtProgressZero() {
        XCTAssertEqual(RuleWipeMath.alpha(field: 0, progress: 0, softness: 0), 0)
        XCTAssertEqual(RuleWipeMath.alpha(field: 0, progress: 0.5, softness: 0), 1)
        XCTAssertEqual(RuleWipeMath.alpha(field: 1, progress: 1, softness: 0), 1)
    }
    func testFeatherBandIsUniformInPixels() {
        let top = FeatherMath.alpha(x: 0.5, y: 5.0 / 100, feather: 0.1, aspect: 4)
        let left = FeatherMath.alpha(x: 5.0 / 400, y: 0.5, feather: 0.1, aspect: 4)
        XCTAssertEqual(top, 0.5, accuracy: 1e-9)
        XCTAssertEqual(left, 0.5, accuracy: 1e-9)
    }
}
