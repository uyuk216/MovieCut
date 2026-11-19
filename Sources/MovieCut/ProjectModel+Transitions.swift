import Foundation
import AppKit
import MovieCutCore

/// トランジションと音声フェード(インスペクタ・メニュー・タイムラインの三角が呼ぶ)。
/// 計算は MovieCutCore の TransitionEditing に任せ、ここは Undo・選択・状態表示だけ。
/// 映像のトランジションの長さを変える編集は、音声が「同じ長さ」に連動しているときは音声も合わせる(1 回の Undo)。
extension ProjectModel {
    static func undoName(forTransition edge: TransitionEdge) -> String { "\(edge.label)トランジションの変更" }

    /// 種類を選ぶ(nil で外す)。
    func setTransitionKind(_ kind: TransitionKind?, edge: TransitionEdge, clipId: String? = nil) {
        guard !isLocked else { return }
        setClipProperty({ c in TransitionEditing.edit(&c) { _ = TransitionEditing.setKind(&$0, edge: edge, kind: kind) } },
                        name: kind == nil ? "\(edge.label)トランジションを外す" : Self.undoName(forTransition: edge), clipId: clipId)
    }

    /// 長さ(秒)を入力欄で確定。
    func setTransitionDuration(_ d: Double, edge: TransitionEdge, clipId: String? = nil) {
        guard !isLocked else { return }
        setClipProperty({ c in TransitionEditing.edit(&c) { _ = TransitionEditing.setDuration(&$0, edge: edge, d) } },
                        name: "\(edge.label)トランジションの長さの変更", clipId: clipId)
    }

    /// ステッパーなどの連続編集。
    func coalescedTransitionDuration(_ d: Double, edge: TransitionEdge, clipId: String? = nil) {
        guard !isLocked else { return }
        coalescedClipProperty({ c in TransitionEditing.edit(&c) { _ = TransitionEditing.setDuration(&$0, edge: edge, d) } },
                              name: "\(edge.label)トランジションの長さの変更", clipId: clipId)
    }

    /// タイムラインの三角のドラッグ中(`beginGesture` 〜 `commitGesture` の間)。
    func liveTransitionDuration(_ d: Double, edge: TransitionEdge, clipId: String) {
        liveClipProperty({ c in TransitionEditing.edit(&c) { _ = TransitionEditing.setDuration(&$0, edge: edge, d) } },
                         name: "\(edge.label)トランジションの長さの変更", clipId: clipId)
    }

    func setTransitionEase(_ e: Ease, edge: TransitionEdge, clipId: String? = nil) {
        guard !isLocked else { return }
        setClipProperty({ _ = TransitionEditing.setEase(&$0, edge: edge, e) }, name: "\(edge.label)トランジションの進み方の変更", clipId: clipId)
    }

    /// ルールワイプの「やわらかさ」。
    func setTransitionRuleSoftness(_ v: Double, edge: TransitionEdge, clipId: String? = nil) {
        guard !isLocked else { return }
        setClipProperty({ _ = TransitionEditing.setRuleSoftness(&$0, edge: edge, v) }, name: "\(edge.label)トランジションのやわらかさの変更", clipId: clipId)
    }

    /// ルールワイプの「やわらかさ」(ステッパーなどの連続編集)。
    func coalescedTransitionRuleSoftness(_ v: Double, edge: TransitionEdge, clipId: String? = nil) {
        guard !isLocked else { return }
        coalescedClipProperty({ _ = TransitionEditing.setRuleSoftness(&$0, edge: edge, v) }, name: "\(edge.label)トランジションのやわらかさの変更", clipId: clipId)
    }

    /// カスタムルール画像の素材の場所。
    func setTransitionRuleSource(_ src: String?, edge: TransitionEdge, clipId: String? = nil) {
        guard !isLocked else { return }
        setClipProperty({ _ = TransitionEditing.setRuleSource(&$0, edge: edge, src) }, name: "\(edge.label)トランジションのルール画像の変更", clipId: clipId)
    }

    /// モーフカットの「強さ」。
    func setTransitionMorphStrength(_ v: Double, edge: TransitionEdge, clipId: String? = nil) {
        guard !isLocked else { return }
        setClipProperty({ _ = TransitionEditing.setMorphStrength(&$0, edge: edge, v) }, name: "\(edge.label)トランジションのモーフの強さの変更", clipId: clipId)
    }

    /// モーフカットの「強さ」(ステッパーなどの連続編集)。
    func coalescedTransitionMorphStrength(_ v: Double, edge: TransitionEdge, clipId: String? = nil) {
        guard !isLocked else { return }
        coalescedClipProperty({ _ = TransitionEditing.setMorphStrength(&$0, edge: edge, v) }, name: "\(edge.label)トランジションのモーフの強さの変更", clipId: clipId)
    }

    /// モーフカットの「顔の位置合わせを優先」。
    func setTransitionMorphFacePriority(_ on: Bool, edge: TransitionEdge, clipId: String? = nil) {
        guard !isLocked else { return }
        setClipProperty({ _ = TransitionEditing.setMorphFacePriority(&$0, edge: edge, on) }, name: "\(edge.label)トランジションの顔の位置合わせの変更", clipId: clipId)
    }

    // MARK: 音声フェード

    func setAudioFade(_ seconds: Double, edge: TransitionEdge, clipId: String? = nil) {
        guard !isLocked else { return }
        setClipProperty({ _ = TransitionEditing.setAudioFade(&$0, edge: edge, seconds) }, name: edge == .in ? "フェードインの変更" : "フェードアウトの変更", clipId: clipId)
    }

    func coalescedAudioFade(_ seconds: Double, edge: TransitionEdge, clipId: String? = nil) {
        guard !isLocked else { return }
        coalescedClipProperty({ _ = TransitionEditing.setAudioFade(&$0, edge: edge, seconds) }, name: edge == .in ? "フェードインの変更" : "フェードアウトの変更", clipId: clipId)
    }

    func setFadeCurve(equalPower: Bool, clipId: String? = nil) {
        guard !isLocked else { return }
        setClipProperty({ _ = TransitionEditing.setFadeCurve(&$0, equalPower: equalPower) }, name: "フェードの曲線の変更", clipId: clipId)
    }

    /// 「映像のトランジションと同じ長さで音声もフェード」。
    func setAudioLinked(_ on: Bool, clipId: String? = nil) {
        guard !isLocked else { return }
        setClipProperty({ _ = TransitionEditing.setAudioLinked(&$0, on) }, name: "音声フェードの連動の切り替え", clipId: clipId)
    }

    // MARK: メニューの操作

    /// 「両方にフェードを付ける」(⌥⌘F)。
    @discardableResult
    func fadeBothSelected() -> Bool {
        guard !isLocked, let c = selectedClip else { return false }
        var probe = c
        guard TransitionEditing.fadeBoth(&probe) else { return false }
        setClipProperty({ c in TransitionEditing.edit(&c) { _ = TransitionEditing.fadeBoth(&$0) } }, name: "両方にフェードを付ける", clipId: c.id)
        return true
    }

    /// 「トランジションをすべて外す」。
    @discardableResult
    func clearTransitionsSelected() -> Bool {
        guard !isLocked, let c = selectedClip, c.hasTransition else { return false }
        setClipProperty({ c in TransitionEditing.edit(&c) { _ = TransitionEditing.clearAll(&$0) } }, name: "トランジションをすべて外す", clipId: c.id)
        return true
    }

    /// 「フェードイン・アウトを付ける」(0.5 秒。映像と音声)。
    @discardableResult
    func fadeInOutSelected() -> Bool {
        guard !isLocked, let c = selectedClip else { return false }
        var probe = c
        guard TransitionEditing.fadeInOut(&probe) else { return false }
        setClipProperty({ _ = TransitionEditing.fadeInOut(&$0) }, name: "フェードイン・アウトを付ける", clipId: c.id)
        return true
    }

    /// 「クロスフェードにする」: 下(前)のクリップとの重なりに合わせて、頭にフェードを付ける。重なりが無いときは何もせず、状態欄に理由を出す。
    @discardableResult
    func crossfadeSelected() -> Bool {
        guard !isLocked, let c = selectedClip else { return false }
        switch TransitionEditing.crossfade(in: project, clipId: c.id) {
        case .applied(let p, let secs, _):
            edit("クロスフェードにする") { $0 = p }
            statusText = "クロスフェードにしました（\(String(format: "%.2f", secs)) 秒）"
            return true
        case .notSupported:
            statusText = "クロスフェードにできるのは、画像・動画・テキストのクリップです"
        case .noClipBelow:
            statusText = "クロスフェードにするには、下のレイヤーのクリップと重ねてください（頭の時刻で重なっている必要があります）"
        case .noOverlap:
            statusText = "下のクリップとの重なりが短すぎます（0.05 秒以上重ねてください）"
        }
        return false
    }

    /// 「重ねてクロスフェード」: 選んだクリップを前へずらして前のクリップと重ね、その重なりでクロスフェードにする。1 回の Undo。
    @discardableResult
    func overlapCrossfadeSelected() -> Bool {
        guard !isLocked, let c = selectedClip else { return false }
        switch TransitionEditing.overlapCrossfade(in: project, clipId: c.id) {
        case .applied(let p, let secs, let shifted):
            edit("重ねてクロスフェード") { $0 = p }
            statusText = shifted > 0
                ? "クリップを \(String(format: "%.2f", shifted)) 秒前へずらして重ね、クロスフェードにしました（\(String(format: "%.2f", secs)) 秒）"
                : "クロスフェードにしました（\(String(format: "%.2f", secs)) 秒）"
            return true
        case .notSupported:
            statusText = "重ねてクロスフェードにできるのは、画像・動画・テキストのクリップです"
        case .noPreviousClip:
            statusText = "前にクリップがありません（同じレイヤーで前にクリップがあるときに使えます）"
        case .locked:
            statusText = "ロックされたクリップ・レイヤーには使えません"
        case .noRoom:
            statusText = "前へずらす余地がありません（前のクリップとの間隔が足りません）"
        }
        return false
    }

    /// タイムラインの三角のドラッグ: `base` から、頭(終わり)の長さを `seconds` にした Project(`updateGesture` 用)。
    /// 音声フェードだけのクリップ(`audio`)は音声のフェード秒、映像のクリップはトランジションの長さ(連動中なら音声も)。
    func projectSettingFadeLength(base: Project, clipId: String, edge: TransitionEdge, seconds: Double, audio: Bool) -> Project? {
        guard let loc = ClipEditing.locate(clipId, in: base) else { return nil }
        var p = base
        var c = p.tracks[loc.track].clips[loc.index]
        TransitionEditing.edit(&c) {
            if audio { _ = TransitionEditing.setAudioFade(&$0, edge: edge, max(MovieCutCore.Transition.minDuration, seconds)) }
            else { _ = TransitionEditing.setDuration(&$0, edge: edge, seconds) }
        }
        p.tracks[loc.track].clips[loc.index] = c
        return p
    }
}
