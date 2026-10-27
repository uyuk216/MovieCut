import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import MovieCutCore

/// トランジションの計算(各種類の境界値・イージング・重なり)と、編集の純粋な計算。
final class TransitionMathTests: XCTestCase {
    func clip(duration: Double = 4, tin: Transition? = nil, tout: Transition? = nil) -> Clip {
        var c = Clip(); c.type = .image; c.start = 10; c.duration = duration; c.transitionIn = tin; c.transitionOut = tout
        return c
    }
    func lin(_ k: TransitionKind, _ d: Double = 1) -> Transition { Transition(k, duration: d, ease: .linear) }

    // MARK: 境界値(頭 0 と 全長、終わり)

    func testNoTransitionIsIdentityEverywhere() {
        let c = clip()
        for t in [9.0, 10, 11, 13.99, 14] { XCTAssertTrue(TransitionMath.apply(c, t: t).isIdentity) }
    }

    func testEveryKindStartsHiddenAndEndsIdentity() {
        for k in TransitionKind.allCases {
            let c = clip(tin: lin(k))
            let s0 = TransitionMath.apply(c, t: 10, size: (0.5, 0.5))
            XCTAssertFalse(s0.isIdentity, "\(k) の頭は効いている")
            // 全長に達した瞬間(と、それ以降)は何も変えない
            XCTAssertTrue(TransitionMath.apply(c, t: 11, size: (0.5, 0.5)).isIdentity, "\(k) の全長")
            XCTAssertTrue(TransitionMath.apply(c, t: 12, size: (0.5, 0.5)).isIdentity, "\(k) の後")
            // 終わり側: 最後のコマ付近は効き、全長前までは何も変えない
            let o = clip(tout: lin(k))
            XCTAssertTrue(TransitionMath.apply(o, t: 13, size: (0.5, 0.5)).isIdentity, "\(k) out の手前")
            XCTAssertFalse(TransitionMath.apply(o, t: 13.999, size: (0.5, 0.5)).isIdentity, "\(k) out の最後")
        }
    }

    func testFadeValues() {
        let c = clip(tin: lin(.fade), tout: lin(.fade))
        XCTAssertEqual(TransitionMath.apply(c, t: 10).opacityMul, 0, accuracy: 1e-12)
        XCTAssertEqual(TransitionMath.apply(c, t: 10.25).opacityMul, 0.25, accuracy: 1e-12)
        XCTAssertEqual(TransitionMath.apply(c, t: 10.5).opacityMul, 0.5, accuracy: 1e-12)
        XCTAssertEqual(TransitionMath.apply(c, t: 12).opacityMul, 1, accuracy: 1e-12)
        XCTAssertEqual(TransitionMath.apply(c, t: 13.5).opacityMul, 0.5, accuracy: 1e-12)
        XCTAssertEqual(TransitionMath.apply(c, t: 13.75).opacityMul, 0.25, accuracy: 1e-12)
    }

    func testZoomBlurSpin() {
        let z = clip(tin: lin(.zoom), tout: lin(.zoom))
        XCTAssertEqual(TransitionMath.apply(z, t: 10.5).scaleMul, 0.5, accuracy: 1e-12)
        XCTAssertEqual(TransitionMath.apply(z, t: 10).scaleMul, 1e-4, accuracy: 1e-12)   // 0 にはしない
        XCTAssertEqual(TransitionMath.apply(z, t: 13.5).scaleMul, 0.5, accuracy: 1e-12)
        let b = clip(tin: lin(.blur))
        let sb = TransitionMath.apply(b, t: 10.25)
        XCTAssertEqual(sb.blurAdd, 45, accuracy: 1e-9); XCTAssertEqual(sb.opacityMul, 0.25, accuracy: 1e-12)
        XCTAssertEqual(TransitionMath.apply(b, t: 10).blurAdd, 60, accuracy: 1e-9)
        let s = clip(tin: lin(.spin), tout: lin(.spin))
        XCTAssertEqual(TransitionMath.apply(s, t: 10).rotationAdd, -90, accuracy: 1e-9)
        XCTAssertEqual(TransitionMath.apply(s, t: 10.5).rotationAdd, -45, accuracy: 1e-9)
        XCTAssertEqual(TransitionMath.apply(s, t: 13.5).rotationAdd, 45, accuracy: 1e-9)     // 終わりは反対回り
        XCTAssertEqual(TransitionMath.apply(s, t: 10.5).opacityMul, 0.5, accuracy: 1e-12)
    }

    func testSlideOffsetsReachOffCanvas() {
        // 中心 (0.3, 0.6)、枠 0.2 × 0.4: 左へ出し切る = 中心 + 半幅 だけ左へ
        func off(_ k: TransitionKind, rel: Double, edge: TransitionEdge = .in) -> (Double, Double) {
            var c = clip(); c.x = 0.3; c.y = 0.6
            if edge == .in { c.transitionIn = lin(k) } else { c.transitionOut = lin(k) }
            let t = edge == .in ? 10 + rel : 14 - 1 + rel
            let s = TransitionMath.apply(c, t: t, size: (0.2, 0.4))
            return (s.offsetX, s.offsetY)
        }
        XCTAssertEqual(off(.slideLeft, rel: 0).0, -(0.3 + 0.1), accuracy: 1e-12)
        XCTAssertEqual(off(.slideRight, rel: 0).0, 1 - 0.3 + 0.1, accuracy: 1e-12)
        XCTAssertEqual(off(.slideUp, rel: 0).1, -(0.6 + 0.2), accuracy: 1e-12)
        XCTAssertEqual(off(.slideDown, rel: 0).1, 1 - 0.6 + 0.2, accuracy: 1e-12)
        XCTAssertEqual(off(.slideLeft, rel: 0.5).0, -0.2, accuracy: 1e-12)              // 半分
        // 終わり: 同じ側へ出ていく(最後のコマ付近でほぼ出し切る)
        XCTAssertEqual(off(.slideLeft, rel: 0.999, edge: .out).0, -(0.3 + 0.1) * 0.999, accuracy: 1e-9)
        XCTAssertEqual(off(.slideLeft, rel: 0, edge: .out).0, 0, accuracy: 1e-12)
        // 中心・枠の大きさを渡さなくても、画面の外までは出る(中心 0.5、枠 0)
        var c = clip(tin: lin(.slideLeft)); c.x = nil
        XCTAssertEqual(TransitionMath.apply(c, t: 10).offsetX, -0.5, accuracy: 1e-12)
    }

    func testWipeMasks() {
        func mask(_ k: TransitionKind, _ rel: Double, edge: TransitionEdge = .in) -> TransitionMask? {
            let c = edge == .in ? clip(tin: lin(k)) : clip(tout: lin(k))
            return TransitionMath.apply(c, t: edge == .in ? 10 + rel : 13 + rel).mask
        }
        XCTAssertEqual(mask(.wipeRight, 0.5), .rect(x: 0, y: 0, w: 0.5, h: 1))             // 左半分が見える
        XCTAssertEqual(mask(.wipeLeft, 0.5), .rect(x: 0.5, y: 0, w: 0.5, h: 1))
        XCTAssertEqual(mask(.wipeDown, 0.25), .rect(x: 0, y: 0, w: 1, h: 0.25))
        XCTAssertEqual(mask(.wipeUp, 0.25), .rect(x: 0, y: 0.75, w: 1, h: 0.25))
        XCTAssertEqual(mask(.wipeCircle, 0.5), .circle(0.5))
        XCTAssertEqual(mask(.wipeClock, 0.5), .clock(0.5))
        XCTAssertEqual(mask(.wipeRight, 0, edge: .in)?.isEmpty, true)
        // 終わり: 消す線が同じ向きに進む(wipeRight は左から消えていく)
        XCTAssertEqual(mask(.wipeRight, 0.5, edge: .out), .rect(x: 0.5, y: 0, w: 0.5, h: 1))
        XCTAssertEqual(mask(.wipeLeft, 0.5, edge: .out), .rect(x: 0, y: 0, w: 0.5, h: 1))
        XCTAssertEqual(mask(.wipeDown, 0.75, edge: .out), .rect(x: 0, y: 0.75, w: 1, h: 0.25))
    }

    // MARK: イージング・長さ・重なり

    func testEasingApplies() {
        var c = clip(tin: Transition(.fade, duration: 1, ease: .easeIn))
        let slow = TransitionMath.apply(c, t: 10.5).opacityMul
        XCTAssertEqual(slow, Ease.easeIn.apply(0.5), accuracy: 1e-12)
        XCTAssertLessThan(slow, 0.5)
        c.transitionIn = Transition(.fade, duration: 1, ease: .easeOut)
        XCTAssertGreaterThan(TransitionMath.apply(c, t: 10.5).opacityMul, 0.5)
        c.transitionIn = Transition(.fade, duration: 1, ease: .easeInOut)
        XCTAssertEqual(TransitionMath.apply(c, t: 10.5).opacityMul, 0.5, accuracy: 1e-6)
        c.transitionIn = Transition(.fade, duration: 1, ease: .hold)
        XCTAssertEqual(TransitionMath.apply(c, t: 10.9).opacityMul, 0, accuracy: 1e-12)
        // 終わりのイージングは「ゆっくり開始 = ゆっくり消え始める」: 経った割合にかけて、1 から減らす
        let o = clip(tout: Transition(.fade, duration: 1, ease: .easeIn))
        XCTAssertEqual(TransitionMath.apply(o, t: 13.25).opacityMul, 1 - Ease.easeIn.apply(0.25), accuracy: 1e-12)
        XCTAssertGreaterThan(TransitionMath.apply(o, t: 13.25).opacityMul, 0.9)
    }

    func testDurationClamping() {
        XCTAssertEqual(Transition.clampedDuration(10, clipDuration: 20), 5)            // 上限 5 秒
        XCTAssertEqual(Transition.clampedDuration(10, clipDuration: 4), 2)             // クリップの半分
        XCTAssertEqual(Transition.clampedDuration(0.001, clipDuration: 4), 0.05)       // 下限
        XCTAssertEqual(Transition.clampedDuration(0.5, clipDuration: 0.06), 0.03, accuracy: 1e-12)   // 極端に短い: 半分まで
        XCTAssertEqual(Transition.clampedDuration(.nan, clipDuration: 4), 0.05)
        XCTAssertEqual(Transition.clampedDuration(1, clipDuration: 0), 0)
    }

    func testInAndOutNeverOverlapOnAVeryShortClip() {
        // 0.4 秒のクリップに 5 秒 + 5 秒: 実際はそれぞれ 0.2 秒で、真ん中で両方が効くことはない
        let c = clip(duration: 0.4, tin: lin(.fade, 5), tout: lin(.fade, 5))
        XCTAssertEqual(TransitionMath.apply(c, t: 10.1).opacityMul, 0.5, accuracy: 1e-9)      // in の途中
        XCTAssertEqual(TransitionMath.apply(c, t: 10.2).opacityMul, 1, accuracy: 1e-9)        // 継ぎ目は完全に見える
        XCTAssertEqual(TransitionMath.apply(c, t: 10.3).opacityMul, 0.5, accuracy: 1e-9)      // out の途中
        for i in 0..<40 {
            let t = 10 + Double(i) * 0.01
            let s = TransitionMath.apply(c, t: t)
            XCTAssertGreaterThanOrEqual(s.opacityMul, 0); XCTAssertLessThanOrEqual(s.opacityMul, 1)
        }
    }

    func testUnknownKindIsKeptButDoesNothing() {
        let c = clip(tin: Transition(kind: "someFutureKind", duration: 1))
        XCTAssertNil(c.transitionIn?.known)
        XCTAssertTrue(TransitionMath.apply(c, t: 10).isIdentity)
    }

    func testStateIsClampedToUnitInterval() {
        XCTAssertTrue(TransitionMath.state(kind: .fade, edge: .in, u: 1.5).isIdentity)
        XCTAssertEqual(TransitionMath.state(kind: .fade, edge: .in, u: -3).opacityMul, 0)
    }

    // MARK: 音声フェードのゲイン

    func testAudioFadeGainLinear() {
        // 長さ 100、フェードイン 10、フェードアウト 20
        func g(_ p: Int, eq: Bool = false) -> Float { AudioFade.gain(pos: p, length: 100, fadeIn: 10, fadeOut: 20, equalPower: eq) }
        XCTAssertEqual(g(0), 0)
        XCTAssertEqual(g(5), 0.5, accuracy: 1e-6)
        XCTAssertEqual(g(10), 1)
        XCTAssertEqual(g(50), 1)
        XCTAssertEqual(g(80), 1, accuracy: 1e-6)            // フェードアウトの入口
        XCTAssertEqual(g(90), 0.5, accuracy: 1e-6)
        XCTAssertEqual(g(99), 1.0 / 20, accuracy: 1e-6)     // 最後のサンプルはほぼ 0
        XCTAssertEqual(g(5, eq: true), sinf(0.25 * .pi), accuracy: 1e-6)    // 等パワーは真ん中で 0.707
        XCTAssertEqual(g(0, eq: true), 0)
        // フェード無しは常に 1
        XCTAssertEqual(AudioFade.gain(pos: 0, length: 100, fadeIn: 0, fadeOut: 0, equalPower: false), 1)
        // 重なる(短いクリップに長いフェード): 両方の積
        XCTAssertEqual(AudioFade.gain(pos: 5, length: 10, fadeIn: 10, fadeOut: 10, equalPower: false), 0.5 * 0.5, accuracy: 1e-6)
    }
}

final class TransitionEditingTests: XCTestCase {
    func img(_ d: Double = 4) -> Clip { var c = Clip(); c.type = .image; c.duration = d; return c }

    func testSetKindKeepsLengthAndEase() {
        var c = img()
        XCTAssertTrue(TransitionEditing.setKind(&c, edge: .in, kind: .zoom))
        XCTAssertEqual(c.transitionIn, Transition(.zoom, duration: 0.5))
        XCTAssertTrue(TransitionEditing.setDuration(&c, edge: .in, 1.2))
        XCTAssertTrue(TransitionEditing.setEase(&c, edge: .in, .linear))
        XCTAssertTrue(TransitionEditing.setKind(&c, edge: .in, kind: .slideLeft))
        XCTAssertEqual(c.transitionIn, Transition(.slideLeft, duration: 1.2, ease: .linear))
        XCTAssertFalse(TransitionEditing.setKind(&c, edge: .in, kind: .slideLeft))          // 変わらない = false
        XCTAssertNil(c.transitionOut)
        XCTAssertTrue(TransitionEditing.setKind(&c, edge: .in, kind: nil))
        XCTAssertNil(c.transitionIn)
        XCTAssertFalse(TransitionEditing.setKind(&c, edge: .in, kind: nil))
    }

    func testDurationIsClampedAndRounded() {
        var c = img(4)
        TransitionEditing.setKind(&c, edge: .out, kind: .fade)
        TransitionEditing.setDuration(&c, edge: .out, 99)
        XCTAssertEqual(c.transitionOut?.duration, 2)
        TransitionEditing.setDuration(&c, edge: .out, 0)
        XCTAssertEqual(c.transitionOut?.duration, 0.05)
        TransitionEditing.setDuration(&c, edge: .out, 0.12345)
        XCTAssertEqual(c.transitionOut?.duration, 0.123)
        XCTAssertFalse(TransitionEditing.setDuration(&c, edge: .out, 0.1234))              // 丸めて同じ
        var empty = img()
        XCTAssertFalse(TransitionEditing.setDuration(&empty, edge: .in, 1))                // 無い側は何もしない
        XCTAssertFalse(TransitionEditing.setEase(&empty, edge: .in, .linear))
    }

    func testShortClipDefaultIsHalfOfClip() {
        var c = img(0.6)
        TransitionEditing.setKind(&c, edge: .in, kind: .fade)
        XCTAssertEqual(c.transitionIn?.duration, 0.3)
    }

    func testNonVisualClipsRefuse() {
        var a = Clip(); a.type = .audio; a.duration = 3
        XCTAssertFalse(TransitionEditing.setKind(&a, edge: .in, kind: .fade))
        XCTAssertFalse(TransitionEditing.fadeBoth(&a))
        var b = Clip(); b.type = .blur; b.duration = 3
        XCTAssertFalse(TransitionEditing.setKind(&b, edge: .in, kind: .fade))
        XCTAssertFalse(TransitionEditing.setAudioFade(&b, edge: .in, 1))
    }

    func testFadeBothAndClearAll() {
        var c = img()
        TransitionEditing.setKind(&c, edge: .in, kind: .zoom)
        TransitionEditing.setDuration(&c, edge: .in, 1)
        XCTAssertTrue(TransitionEditing.fadeBoth(&c))
        XCTAssertEqual(c.transitionIn, Transition(.fade, duration: 1))        // 長さは残す
        XCTAssertEqual(c.transitionOut, Transition(.fade, duration: 0.5))
        XCTAssertFalse(TransitionEditing.fadeBoth(&c))
        XCTAssertTrue(TransitionEditing.clearAll(&c))
        XCTAssertFalse(c.hasTransition)
        XCTAssertFalse(TransitionEditing.clearAll(&c))
    }

    func testFadeInOutQuickAction() {
        var v = Clip(); v.type = .video; v.duration = 6
        XCTAssertTrue(TransitionEditing.fadeInOut(&v))
        XCTAssertEqual(v.transitionIn, Transition(.fade, duration: 0.5)); XCTAssertEqual(v.transitionOut, Transition(.fade, duration: 0.5))
        XCTAssertEqual(v.fadeIn, 0.5); XCTAssertEqual(v.fadeOut, 0.5)
        XCTAssertFalse(TransitionEditing.fadeInOut(&v))
        var a = Clip(); a.type = .audio; a.duration = 6
        XCTAssertTrue(TransitionEditing.fadeInOut(&a))
        XCTAssertFalse(a.hasTransition); XCTAssertEqual(a.fadeIn, 0.5)
        var t = img(); t.type = .text
        TransitionEditing.fadeInOut(&t)
        XCTAssertTrue(t.hasTransition); XCTAssertNil(t.fadeIn)
        var s = img(0.4)       // 短いクリップは半分まで
        TransitionEditing.fadeInOut(&s)
        XCTAssertEqual(s.transitionIn?.duration, 0.2)
    }

    func testAudioFadeFields() {
        var a = Clip(); a.type = .voice; a.duration = 3
        XCTAssertTrue(TransitionEditing.setAudioFade(&a, edge: .in, 1))
        XCTAssertTrue(TransitionEditing.setFadeCurve(&a, equalPower: true))
        XCTAssertEqual(a.fadeCurve, "equalPower")
        XCTAssertTrue(TransitionEditing.setAudioFade(&a, edge: .out, 99))
        XCTAssertEqual(a.fadeOut, 3)                                               // クリップの長さまで
        XCTAssertTrue(TransitionEditing.setAudioFade(&a, edge: .in, 0))
        XCTAssertNil(a.fadeIn)
        TransitionEditing.setAudioFade(&a, edge: .out, 0)
        XCTAssertNil(a.fadeCurve)                                                  // フェードが無ければ曲線も消す
        XCTAssertFalse(TransitionEditing.setAudioFade(&a, edge: .out, 0))
    }

    func testAudioLinkFollowsTransitionLengths() {
        var v = Clip(); v.type = .video; v.duration = 8
        XCTAssertFalse(TransitionEditing.isAudioLinked(v))
        TransitionEditing.setKind(&v, edge: .in, kind: .fade)
        TransitionEditing.setDuration(&v, edge: .in, 1)
        XCTAssertFalse(TransitionEditing.isAudioLinked(v))
        XCTAssertTrue(TransitionEditing.setAudioLinked(&v, true))
        XCTAssertEqual(v.fadeIn, 1); XCTAssertNil(v.fadeOut)                       // 無い側は付けない
        XCTAssertTrue(TransitionEditing.isAudioLinked(v))
        // 連動中に長さを変えると音声も追従する
        TransitionEditing.edit(&v) { _ = TransitionEditing.setDuration(&$0, edge: .in, 2) }
        XCTAssertEqual(v.fadeIn, 2); XCTAssertTrue(TransitionEditing.isAudioLinked(v))
        // 連動していないときは追従しない
        TransitionEditing.setAudioFade(&v, edge: .in, 0.3)
        TransitionEditing.edit(&v) { _ = TransitionEditing.setDuration(&$0, edge: .in, 1) }
        XCTAssertEqual(v.fadeIn, 0.3)
        XCTAssertTrue(TransitionEditing.setAudioLinked(&v, false))
        XCTAssertNil(v.fadeIn)
        var img = Clip(); img.type = .image; img.duration = 4
        XCTAssertFalse(TransitionEditing.setAudioLinked(&img, true))
    }

    // MARK: クロスフェード

    func layered(lowerStart: Double = 0, lowerDur: Double = 3, upperStart: Double = 2, upperDur: Double = 4) -> Project {
        var lo = Clip(); lo.id = "lo"; lo.type = .image; lo.start = lowerStart; lo.duration = lowerDur
        var up = Clip(); up.id = "up"; up.type = .image; up.start = upperStart; up.duration = upperDur
        var p = Project(); p.tracks = [Track(name: "下"), Track(name: "上")]
        p.tracks[0].clips = [lo]; p.tracks[1].clips = [up]
        return p
    }

    func testCrossfadeSetsFadeInToTheOverlap() throws {
        guard case .applied(let p, let secs, let under) = TransitionEditing.crossfade(in: layered(), clipId: "up") else { return XCTFail("掛からない") }
        XCTAssertEqual(secs, 1); XCTAssertEqual(under, "lo")
        XCTAssertEqual(p.tracks[1].clips[0].transitionIn, Transition(.fade, duration: 1))
        XCTAssertEqual(p.tracks[0].clips[0], layered().tracks[0].clips[0])        // 下は変えない
        XCTAssertEqual(p.tracks[1].clips[0].duration, 4)                           // 何も伸ばさない
        // 長い重なりは、上のクリップの半分まで
        guard case .applied(_, let s2, _) = TransitionEditing.crossfade(in: layered(lowerDur: 6, upperStart: 1, upperDur: 2), clipId: "up") else { return XCTFail() }
        XCTAssertEqual(s2, 1)
        // すでにある進み方は残し、種類だけフェードにする
        var q = layered(); q.tracks[1].clips[0].transitionIn = Transition(.zoom, duration: 0.2, ease: .linear)
        guard case .applied(let r, _, _) = TransitionEditing.crossfade(in: q, clipId: "up") else { return XCTFail() }
        XCTAssertEqual(r.tracks[1].clips[0].transitionIn, Transition(.fade, duration: 1, ease: .linear))
    }

    func testCrossfadeWithoutOverlapChangesNothing() {
        XCTAssertEqual(TransitionEditing.crossfade(in: layered(lowerDur: 2, upperStart: 2), clipId: "up"), .noClipBelow)   // 接するだけ
        XCTAssertEqual(TransitionEditing.crossfade(in: layered(lowerDur: 1, upperStart: 5), clipId: "up"), .noClipBelow)
        XCTAssertEqual(TransitionEditing.crossfade(in: layered(lowerDur: 2.03, upperStart: 2), clipId: "up"), .noOverlap)   // 0.05 秒未満
        // 下のレイヤーが音声だけなら対象外
        var p = layered(); p.tracks[0].clips[0].type = .audio
        XCTAssertEqual(TransitionEditing.crossfade(in: p, clipId: "up"), .noClipBelow)
        // 下のクリップを選んだとき(上のクリップはこちらの下ではない)
        XCTAssertEqual(TransitionEditing.crossfade(in: layered(), clipId: "lo"), .noClipBelow)
        XCTAssertEqual(TransitionEditing.crossfade(in: layered(), clipId: "nothing"), .notSupported)
    }

    func testCrossfadeFindsTheNearestBelowAndSameLayerPredecessor() {
        var mid = Clip(); mid.id = "mid"; mid.type = .image; mid.start = 1; mid.duration = 2.5
        var p = layered(); p.tracks.insert({ var t = Track(name: "中"); t.clips = [mid]; return t }(), at: 1)
        guard case .applied(_, let s, let under) = TransitionEditing.crossfade(in: p, clipId: "up") else { return XCTFail() }
        XCTAssertEqual(under, "mid"); XCTAssertEqual(s, 1.5)                        // 一番近い下のレイヤー
        // 同じレイヤーで前のクリップと重なっているとき
        var q = Project(); var a = Clip(); a.id = "a"; a.type = .image; a.start = 0; a.duration = 3
        var b = Clip(); b.id = "b"; b.type = .image; b.start = 2; b.duration = 3
        q.tracks = [Track(name: "x")]; q.tracks[0].clips = [a, b]
        guard case .applied(_, let s3, let u3) = TransitionEditing.crossfade(in: q, clipId: "b") else { return XCTFail() }
        XCTAssertEqual(u3, "a"); XCTAssertEqual(s3, 1)
    }

    func testSplitGivesInToLeftAndOutToRight() {
        var c = img(4); c.start = 1
        c.transitionIn = Transition(.zoom, duration: 0.5); c.transitionOut = Transition(.fade, duration: 0.7)
        c.fadeIn = 0.5; c.fadeOut = 0.7
        let (l, r) = ClipEditing.split(c, at: 3)!
        XCTAssertNotNil(l.transitionIn); XCTAssertNil(l.transitionOut); XCTAssertEqual(l.fadeIn, 0.5); XCTAssertNil(l.fadeOut)
        XCTAssertNil(r.transitionIn); XCTAssertNotNil(r.transitionOut); XCTAssertNil(r.fadeIn); XCTAssertEqual(r.fadeOut, 0.7)
    }
}

// MARK: - ファイル

final class TransitionFileTests: XCTestCase {
    func fixtureURL(_ name: String, ext: String = "ymproj") throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
    }

    func testOldFixturesStillSerializeByteForByte() throws {
        for n in ["rich", "electron-made"] {
            let out = try Project.load(from: fixtureURL(n)).encoded()
            XCTAssertEqual(out, try Data(contentsOf: fixtureURL("golden-\(n)", ext: "json")), n)
            let s = String(decoding: out, as: UTF8.self)
            for k in ["transitionIn", "transitionOut", "fadeIn", "fadeOut", "fadeCurve"] { XCTAssertFalse(s.contains(k), "\(n) に \(k) が増えた") }
        }
    }

    func testPlainClipsWriteNoTransitionKeys() throws {
        var c = Clip(); c.type = .video; c.src = "/a.mp4"
        var p = Project(); p.tracks = [Track(name: "t")]; p.tracks[0].clips = [c]
        let s = String(decoding: try p.encoded(), as: UTF8.self)
        for k in ["transition", "fadeIn", "fadeOut", "fadeCurve"] { XCTAssertFalse(s.contains(k), k) }
    }

    func testRichTransitionFixtureRoundTrips() throws {
        let p1 = try Project.load(from: fixtureURL("transitions"))
        let img = p1.allClips.first { $0.id == "timg" }!
        XCTAssertEqual(img.transitionIn?.known, .zoom); XCTAssertEqual(img.transitionIn?.duration, 0.8); XCTAssertEqual(img.transitionIn?.ease, .easeOut)
        XCTAssertEqual(img.transitionOut?.known, .slideLeft); XCTAssertEqual(img.transitionOut?.ease, .easeInOut)       // 既定
        XCTAssertEqual(img.transitionOut?.extra["futureTransitionKey"], .array([.number(1), .number(2)]))
        XCTAssertEqual(img.extra["futureClipKey"], .string("keep"))
        let txt = p1.allClips.first { $0.id == "ttxt" }!
        XCTAssertEqual(txt.transitionIn?.known, .blur)
        XCTAssertNil(txt.transitionOut?.known)                                       // 知らない種類は残るが無効
        XCTAssertEqual(txt.transitionOut?.kind, "someFutureKind")
        XCTAssertEqual(txt.transitionOut?.params, .object(["angle": .number(30)]))
        let aud = p1.allClips.first { $0.id == "taud" }!
        XCTAssertEqual(aud.fadeIn, 0.5); XCTAssertEqual(aud.fadeOut, 1.25); XCTAssertEqual(aud.fadeCurve, "equalPower")
        XCTAssertTrue(aud.fadeIsEqualPower)

        let data1 = try p1.encoded()
        XCTAssertEqual(p1, try Project.decode(from: data1))
        XCTAssertEqual(try Project.decode(from: data1).encoded(), data1)              // 書き戻しが安定
        let s = String(decoding: data1, as: UTF8.self)
        XCTAssertTrue(s.contains("someFutureKind")); XCTAssertTrue(s.contains("futureTransitionKey")); XCTAssertTrue(s.contains("\"angle\""))
        XCTAssertFalse(s.contains("easeInOut"))                                       // 既定のなめらかは書かない
        XCTAssertTrue(s.contains("easeOut"))
    }

    func testUnreadableTransitionIsKeptVerbatim() throws {
        let p = try Project.load(from: fixtureURL("transitions"))
        let bad = p.allClips.first { $0.id == "tbad" }!
        XCTAssertNil(bad.transitionIn)
        XCTAssertEqual(bad.extra["transitionIn"], .string("this is not a transition"))
        XCTAssertTrue(String(decoding: try p.encoded(), as: UTF8.self).contains("this is not a transition"))
    }

    func testLenientTransitionFields() throws {
        let json = #"{"tracks":[{"clips":[{"type":"image","transitionIn":{"kind":"fade","duration":"x","ease":"zzz"},"transitionOut":{"duration":2},"fadeIn":"a","fadeOut":-3}]}]}"#
        let c = try Project.decode(from: Data(json.utf8)).tracks[0].clips[0]
        XCTAssertEqual(c.transitionIn?.duration, 0.5)                              // 読めない長さは既定
        XCTAssertEqual(c.transitionIn?.ease, .linear)                              // 読めない進み方は linear(キーフレームと同じ)
        XCTAssertEqual(c.transitionOut?.kind, ""); XCTAssertNil(c.transitionOut?.known)
        XCTAssertNil(c.fadeIn)
        XCTAssertEqual(c.fadeOutOrDefault, 0)                                       // 負は 0 とみなす
    }
}

// MARK: - 描画(画素)

final class TransitionRendererTests: XCTestCase {
    struct Pixels {
        let w: Int, h: Int
        var d: [UInt8]
        func rgb(_ x: Int, _ y: Int) -> [Int] { let i = (y * w + x) * 4; return [Int(d[i]), Int(d[i + 1]), Int(d[i + 2])] }
        func white(_ x: Int, _ y: Int) -> Bool { rgb(x, y)[0] > 200 }
        var whiteCount: Int { (0..<(w * h)).filter { d[$0 * 4] > 128 }.count }
    }

    func pixels(_ img: CGImage) -> Pixels {
        var d = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let c = CGContext(data: &d, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return Pixels(w: img.width, h: img.height, d: d)
    }

    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("transition-tests-\(UUID().uuidString)")
    override func setUpWithError() throws { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    let W = 64, H = 36

    func solid(_ name: String, r: UInt8, g: UInt8, b: UInt8, w: Int? = nil, h: Int? = nil) throws -> String {
        let w = w ?? W, h = h ?? H
        let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1))
        c.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let url = tmp.appendingPathComponent(name)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, c.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url.path
    }

    func clip(_ path: String, start: Double = 0, dur: Double = 4, tin: Transition? = nil, tout: Transition? = nil, scale: Double = 1) -> Clip {
        var c = Clip(); c.id = UUID().uuidString; c.type = .image; c.src = path; c.start = start; c.duration = dur
        c.x = 0.5; c.y = 0.5; c.scale = scale; c.transitionIn = tin; c.transitionOut = tout
        return c
    }

    func project(_ layers: [[Clip]]) -> Project {
        var p = Project(); p.width = W; p.height = H; p.bg = "#000000"; p.characters = []
        p.tracks = layers.enumerated().map { i, cs in var t = Track(name: "L\(i)"); t.clips = cs; return t }
        return p
    }

    func render(_ p: Project, _ t: Double) throws -> Pixels {
        pixels(try XCTUnwrap(Renderer(project: p, assets: RenderAssets()).renderImage(t: t)))
    }

    func testFadeAtHalfIsHalfAlpha() throws {
        let white = try solid("w.png", r: 255, g: 255, b: 255)
        let p = project([[clip(white, tin: Transition(.fade, duration: 1, ease: .linear))]])
        let mid = try render(p, 0.5)
        for (x, y) in [(2, 2), (32, 18), (60, 30)] {
            XCTAssertEqual(Double(mid.rgb(x, y)[0]), 127.5, accuracy: 3, "(\(x),\(y))")
        }
        XCTAssertEqual(try render(p, 0.0).rgb(32, 18), [0, 0, 0])               // 頭は真っ暗(背景)
        XCTAssertEqual(try render(p, 1.0).rgb(32, 18), [255, 255, 255])          // 全長に達したらそのまま
        XCTAssertEqual(try render(p, 2.0).rgb(32, 18), [255, 255, 255])
        // 終わりのフェードアウト
        let q = project([[clip(white, tout: Transition(.fade, duration: 1, ease: .linear))]])
        XCTAssertEqual(Double(try render(q, 3.5).rgb(32, 18)[0]), 127.5, accuracy: 3)
        XCTAssertEqual(try render(q, 2.9).rgb(32, 18), [255, 255, 255])
    }

    func testWipeRightRevealsLeftHalfAtHalf() throws {
        let white = try solid("w.png", r: 255, g: 255, b: 255)
        let p = project([[clip(white, tin: Transition(.wipeRight, duration: 1, ease: .linear))]])
        let mid = try render(p, 0.5)
        for y in [2, 18, 33] {
            XCTAssertTrue(mid.white(2, y)); XCTAssertTrue(mid.white(30, y))
            XCTAssertFalse(mid.white(34, y)); XCTAssertFalse(mid.white(61, y))
        }
        // 上下方向
        let d = project([[clip(white, tin: Transition(.wipeDown, duration: 1, ease: .linear))]])
        let m2 = try render(d, 0.5)
        XCTAssertTrue(m2.white(32, 2)); XCTAssertFalse(m2.white(32, 33))
        let l = project([[clip(white, tin: Transition(.wipeLeft, duration: 1, ease: .linear))]])
        let m3 = try render(l, 0.5)
        XCTAssertTrue(m3.white(61, 18)); XCTAssertFalse(m3.white(2, 18))
        // 終わり: wipeRight は左から消える
        let o = project([[clip(white, tout: Transition(.wipeRight, duration: 1, ease: .linear))]])
        let m4 = try render(o, 3.5)
        XCTAssertTrue(m4.white(61, 18)); XCTAssertFalse(m4.white(2, 18))
    }

    func testCircleAndClockCoverageIsMonotonic() throws {
        let white = try solid("w.png", r: 255, g: 255, b: 255)
        for kind in [TransitionKind.wipeCircle, .wipeClock] {
            let p = project([[clip(white, tin: Transition(kind, duration: 1, ease: .linear))]])
            let counts = try [0.1, 0.25, 0.4, 0.55, 0.7, 0.85, 0.99].map { try render(p, $0).whiteCount }
            for i in 1..<counts.count { XCTAssertGreaterThan(counts[i], counts[i - 1], "\(kind) \(counts)") }
            XCTAssertEqual(try render(p, 1.0).whiteCount, W * H)                    // 全長ではぜんぶ見える
            XCTAssertEqual(try render(p, 0.0).whiteCount, 0)
        }
        let c = project([[clip(white, tin: Transition(.wipeCircle, duration: 1, ease: .linear))]])
        let m = try render(c, 0.25)
        XCTAssertTrue(m.white(32, 18)); XCTAssertFalse(m.white(1, 1)); XCTAssertFalse(m.white(62, 34))
        // 時計回り: 1/4 では右上だけ、1/2 では右半分
        let k = project([[clip(white, tin: Transition(.wipeClock, duration: 1, ease: .linear))]])
        let q = try render(k, 0.25)
        XCTAssertTrue(q.white(50, 5)); XCTAssertFalse(q.white(14, 5)); XCTAssertFalse(q.white(50, 32)); XCTAssertFalse(q.white(14, 32))
        let h = try render(k, 0.5)
        XCTAssertTrue(h.white(50, 5)); XCTAssertTrue(h.white(50, 32)); XCTAssertFalse(h.white(14, 5)); XCTAssertFalse(h.white(14, 32))
    }

    func testSlideLeftMovesClipInFromTheLeft() throws {
        // 半分の大きさ(32×18)の白を中央に。左から入る: 全長で中央、頭では画面の外
        let white = try solid("w.png", r: 255, g: 255, b: 255)
        let p = project([[clip(white, tin: Transition(.slideLeft, duration: 1, ease: .linear), scale: 0.5)]])
        XCTAssertEqual(try render(p, 0.0).whiteCount, 0)                           // 完全に外
        let mid = try render(p, 0.5)       // 中心 x = 0.5 - 0.5 * (0.5 + 0.25) = 0.125 → 8px、幅 32 → [-8, 24)
        XCTAssertTrue(mid.white(4, 18)); XCTAssertTrue(mid.white(20, 18))
        XCTAssertFalse(mid.white(28, 18)); XCTAssertFalse(mid.white(48, 18))
        XCTAssertFalse(mid.white(8, 2))                                              // 縦はそのまま(上の余白は黒)
        let done = try render(p, 1.0)
        XCTAssertTrue(done.white(32, 18)); XCTAssertFalse(done.white(4, 18))
        // 上から入る
        let u = project([[clip(white, tin: Transition(.slideUp, duration: 1, ease: .linear), scale: 0.5)]])
        XCTAssertEqual(try render(u, 0.0).whiteCount, 0)
        let um = try render(u, 0.5)         // 中心 y = 0.5 - 0.5 * (0.5 + 0.25) = 0.125 → 4.5px、高さ 18 → [-4.5, 13.5)
        XCTAssertTrue(um.white(32, 5)); XCTAssertFalse(um.white(32, 20))
    }

    func testZoomGrowsFromTheCentre() throws {
        let white = try solid("w.png", r: 255, g: 255, b: 255)
        let p = project([[clip(white, tin: Transition(.zoom, duration: 1, ease: .linear))]])
        let mid = try render(p, 0.5)
        XCTAssertTrue(mid.white(32, 18)); XCTAssertFalse(mid.white(2, 2)); XCTAssertFalse(mid.white(62, 34))
        XCTAssertEqual(Double(mid.whiteCount), Double(W * H) / 4, accuracy: 60)    // 面積は 1/4
    }

    func testSpinRotatesAndBlurSoftensTheEdge() throws {
        let white = try solid("w.png", r: 255, g: 255, b: 255, w: 32, h: 18)
        // 回転: 半分の大きさの白を -45° 付近まで回した形は、四隅が欠ける(元の長方形と違う)
        let s = project([[clip(white, tin: Transition(.spin, duration: 1, ease: .linear), scale: 1)]])
        let plain = project([[clip(white, scale: 1)]])
        XCTAssertNotEqual(try render(s, 0.5).d, try render(plain, 0.5).d)
        // ぼかし: 半透明の分、全長の絵より暗く、縁がにじむ(境目の画素が中間色になる)
        var half = clip(white, tin: Transition(.blur, duration: 1, ease: .linear), scale: 0.5)
        half.x = 0.5
        let b = project([[half]])
        let bp = try render(b, 0.5)
        let edge = bp.rgb(16, 18)[0]                  // 32 x 18 の絵の左端(x=16)。半透明(約128)の半分ほどに薄れる
        XCTAssertGreaterThan(edge, 5); XCTAssertLessThan(edge, 120)
        XCTAssertEqual(try render(b, 1.0).rgb(32, 18), [255, 255, 255])
    }

    func testCrossfadeBetweenTwoLayers() throws {
        let red = try solid("r.png", r: 255, g: 0, b: 0), blue = try solid("b.png", r: 0, g: 0, b: 255)
        // 下: 赤 0〜3 秒、上: 青 2〜6 秒でフェードイン 1 秒(重なりに合わせる)
        let p = project([[clip(red, start: 0, dur: 3)], [clip(blue, start: 2, dur: 4, tin: Transition(.fade, duration: 1, ease: .linear))]])
        let a = try render(p, 2.0)
        XCTAssertEqual(a.rgb(32, 18), [255, 0, 0])                                  // 重なりの頭は赤のまま
        let mid = try render(p, 2.5)
        XCTAssertEqual(Double(mid.rgb(32, 18)[0]), 127.5, accuracy: 3); XCTAssertEqual(Double(mid.rgb(32, 18)[2]), 127.5, accuracy: 3)
        XCTAssertEqual(mid.rgb(32, 18)[1], 0)
        let b = try render(p, 2.9)
        XCTAssertGreaterThan(b.rgb(32, 18)[2], 220); XCTAssertLessThan(b.rgb(32, 18)[0], 35)
        // 下のクリップが終わったあと(3.0〜)は、青だけ
        XCTAssertEqual(try render(p, 3.5).rgb(32, 18), [0, 0, 255])
        // 3 色を通して赤が青に滑らかに変わる(赤成分は単調に減る)
        let reds = try stride(from: 2.0, to: 3.0, by: 0.1).map { try render(p, $0).rgb(32, 18)[0] }
        for i in 1..<reds.count { XCTAssertLessThanOrEqual(reds[i], reds[i - 1]) }
    }

    func testFramesOutsideTheTransitionAreIdenticalToTheOldPath() throws {
        let white = try solid("w.png", r: 255, g: 255, b: 255)
        var withTr = clip(white, tin: Transition(.zoom, duration: 0.5), tout: Transition(.fade, duration: 0.5))
        withTr.id = "same"
        var without = withTr; without.transitionIn = nil; without.transitionOut = nil
        for t in [1.0, 2.0, 3.0] {
            XCTAssertEqual(try render(project([[withTr]]), t).d, try render(project([[without]]), t).d, "t=\(t)")
        }
        XCTAssertNotEqual(try render(project([[withTr]]), 0.1).d, try render(project([[without]]), 0.1).d)
    }

    func testTextClipsGetTransitionsToo() throws {
        var t = Clip(); t.id = "t"; t.type = .text; t.text = "ABC"; t.start = 0; t.duration = 4; t.x = 0.5; t.y = 0.5; t.fontSize = 24
        t.transitionIn = Transition(.fade, duration: 1, ease: .linear)
        let p = project([[t]])
        let sum = { (px: Pixels) in (0..<(self.W * self.H)).reduce(0) { $0 + Int(px.d[$1 * 4]) } }
        let early = sum(try render(p, 0.3)), later = sum(try render(p, 0.7)), full = sum(try render(p, 2))
        XCTAssertGreaterThan(later, early); XCTAssertGreaterThan(full, later); XCTAssertGreaterThan(early, 0)
    }
}

// MARK: - 音声フェード(ミキサー)

final class AudioFadeMixerTests: XCTestCase {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("fade-tests-\(UUID().uuidString)")
    override func setUpWithError() throws { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func mix(_ clips: [Clip]) throws -> URL {
        var p = Project(); p.tracks = [Track(name: "a")]; p.tracks[0].clips = clips
        let out = tmp.appendingPathComponent("mix-\(UUID().uuidString).caf")
        try AudioMixer.mixdown(project: p, assets: RenderAssets(), to: out)
        return out
    }

    func audio(_ name: String, seconds: Double, amp: Float = 0.5) throws -> String {
        let u = tmp.appendingPathComponent(name)
        try AudioFixture.writeSine(u, sampleRate: 48000, segments: [(seconds, amp)])
        return u.path
    }

    func testFadeInAndOutRampTheMix() throws {
        let path = try audio("s.wav", seconds: 3)
        var c = Clip(); c.type = .audio; c.src = path; c.start = 0; c.duration = 3; c.fadeIn = 0.5; c.fadeOut = 0.5
        let m = try mix([c])
        XCTAssertLessThan(try AudioFixture.peak(m, from: 0, to: 0.002), 0.01)          // 頭はほぼ無音
        XCTAssertEqual(try AudioFixture.peak(m, from: 0.24, to: 0.26), 0.25, accuracy: 0.02)   // ランプの真ん中
        XCTAssertEqual(try AudioFixture.peak(m, from: 1.0, to: 1.5), 0.5, accuracy: 0.01)      // 真ん中は元の音量
        XCTAssertEqual(try AudioFixture.peak(m, from: 2.74, to: 2.76), 0.25, accuracy: 0.02)
        XCTAssertLessThan(try AudioFixture.peak(m, from: 2.998, to: 3.0), 0.01)         // 終わりもほぼ無音
        // フェードの無いクリップは従来どおり
        c.fadeIn = nil; c.fadeOut = nil
        XCTAssertEqual(try AudioFixture.peak(try mix([c]), from: 0, to: 0.05), 0.5, accuracy: 0.01)
    }

    func testEqualPowerCurveIsLouderInTheMiddleOfTheRamp() throws {
        let path = try audio("s.wav", seconds: 2)
        var c = Clip(); c.type = .voice; c.src = path; c.start = 0; c.duration = 2; c.fadeIn = 1
        let lin = try AudioFixture.peak(try mix([c]), from: 0.49, to: 0.51)
        c.fadeCurve = "equalPower"
        let eq = try AudioFixture.peak(try mix([c]), from: 0.49, to: 0.51)
        XCTAssertEqual(lin, 0.25, accuracy: 0.02); XCTAssertEqual(eq, 0.5 * 0.7071, accuracy: 0.02)
    }

    func testFadeIsContinuousAcrossTheTenSecondChunkBoundary() throws {
        // 5〜15 秒の音、フェードアウト 6 秒(9〜15)は 10 秒の塊の境目をまたぐ
        let path = try audio("long.wav", seconds: 10)
        var c = Clip(); c.type = .audio; c.src = path; c.start = 5; c.duration = 10; c.fadeOut = 6
        let m = try mix([c])
        XCTAssertEqual(try AudioFixture.peak(m, from: 9.99, to: 10.0), 0.5 * (5.0 / 6.0), accuracy: 0.01)
        XCTAssertEqual(try AudioFixture.peak(m, from: 10.0, to: 10.01), 0.5 * (5.0 / 6.0), accuracy: 0.01)
        XCTAssertEqual(try AudioFixture.peak(m, from: 7, to: 8), 0.5, accuracy: 0.01)
    }

    func testFadeUsesTheClipsOwnHeadWhenItStartsBeforeZero() throws {
        let path = try audio("s.wav", seconds: 4)
        var c = Clip(); c.type = .audio; c.src = path; c.start = -1; c.duration = 4; c.fadeIn = 2
        let m = try mix([c])       // プロジェクトの 0 秒はクリップの 1 秒目 = フェードインの半分(0.5 倍)
        XCTAssertEqual(try AudioFixture.peak(m, from: 0, to: 0.01), 0.25, accuracy: 0.02)
    }
}
