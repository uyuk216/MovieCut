import Foundation
import MovieCutCore

/// 形のマスク(インスペクタの「形のマスク」)。値は `Clip.mask`(省くと nil)。つまみのドラッグは 1 回の Undo。
extension ProjectModel {
    nonisolated static let maskUndoName = "マスクの変更"

    /// オン(既定のマスク)・オフ(nil に戻す)・形や反転などの離散的な変更。1 回の Undo。
    func setClipMask(_ mask: ClipMask?, clipId: String? = nil, name: String = ProjectModel.maskUndoName) {
        setClipProperty({ $0.mask = mask }, name: name, clipId: clipId)
    }

    /// 1 項目だけ変える(マスクが無ければ既定から作る)。
    func setMaskField(clipId: String, name: String = ProjectModel.maskUndoName, _ change: @escaping (inout ClipMask) -> Void) {
        setClipProperty({ c in
            var m = c.mask ?? ClipMask()
            change(&m)
            c.mask = m
        }, name: name, clipId: clipId)
    }

    /// スライダーのドラッグ中(`beginGesture` 〜 `commitGesture`)。ドラッグ開始時のプロジェクトから毎回計算するので、動かして戻すと元に戻る。
    func liveMaskField(clipId: String, _ change: @escaping (inout ClipMask) -> Void) {
        guard !isLocked, let c = clip(clipId) else { return }
        var p = gestureBase ?? project
        guard let loc = ClipEditing.locate(c.id, in: p) else { return }
        var m = p.tracks[loc.track].clips[loc.index].mask ?? ClipMask()
        change(&m)
        p.tracks[loc.track].clips[loc.index].mask = m
        if gestureBase != nil { updateGesture(p) } else if p != project { edit(Self.maskUndoName) { $0 = p } }
    }
}
