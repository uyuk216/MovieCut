import Foundation
import MovieCutCore

/// 手ぶれ補正(メニュー ▸ クリップ ▸ 手ぶれ補正・インスペクタの強さ)。計算は MovieCutCore(`Stabilizer`)、ここは Undo(1 操作 = 1 回)と選択だけ。
extension ProjectModel {
    static let stabilizeStrengthUndoName = "手ぶれ補正の強さ"

    private func stabilizeTarget(_ clipId: String?) -> Clip? {
        guard !isLocked, let id = clipId ?? selectedClipId, let c = clip(id), StabilizeEditing.supports(c) else { return nil }
        return c
    }

    /// メニューの切り替え。選んでいる映像クリップの手ぶれ補正をオン/オフする(1 回の Undo)。値が変わらなければ何もしない。
    @discardableResult
    func toggleStabilizeSelected() -> Bool {
        guard let c = stabilizeTarget(nil) else { return false }
        var probe = c
        guard StabilizeEditing.toggle(&probe) else { return false }
        setClipProperty({ _ = StabilizeEditing.toggle(&$0) },
                        name: c.stabilizeStrength > 0 ? "手ぶれ補正をオフ" : "手ぶれ補正をオン", clipId: c.id)
        return true
    }

    /// 強さを決める(数値欄の確定)。1 回の Undo。
    @discardableResult
    func setStabilizeStrength(_ v: Double, clipId: String? = nil) -> Bool {
        guard let c = stabilizeTarget(clipId) else { return false }
        var probe = c
        guard StabilizeEditing.setStrength(&probe, v) else { return false }
        flushCoalesced()
        setClipProperty({ _ = StabilizeEditing.setStrength(&$0, v) }, name: Self.stabilizeStrengthUndoName, clipId: c.id)
        return true
    }

    /// スライダーのドラッグ中(`beginGesture` 〜 `commitGesture`)。ドラッグ開始時のプロジェクトから毎回計算するので、動かして戻すと元に戻る。
    func liveStabilizeStrength(_ v: Double, clipId: String) {
        guard let c = stabilizeTarget(clipId) else { return }
        var p = gestureBase ?? project
        guard let loc = ClipEditing.locate(c.id, in: p) else { return }
        _ = StabilizeEditing.setStrength(&p.tracks[loc.track].clips[loc.index], v)
        if gestureBase != nil { updateGesture(p) } else if p != project { edit(Self.stabilizeStrengthUndoName) { $0 = p } }
    }

    /// 傾き・拡大縮小も補正するかどうか(インスペクタのチェック)。1 回の Undo。補正がオフのときは何もしない。
    @discardableResult
    func setStabilizeRotationZoom(_ on: Bool, clipId: String? = nil) -> Bool {
        guard let c = stabilizeTarget(clipId) else { return false }
        var probe = c
        guard StabilizeEditing.setRotationZoom(&probe, on) else { return false }
        flushCoalesced()
        setClipProperty({ _ = StabilizeEditing.setRotationZoom(&$0, on) }, name: on ? "手ぶれ補正の傾き補正をオン" : "手ぶれ補正の傾き補正をオフ", clipId: c.id)
        return true
    }
}
