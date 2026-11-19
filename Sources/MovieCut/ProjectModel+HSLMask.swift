import Foundation
import MovieCutCore

/// HSL マスク(インスペクタの「HSLマスク」)。値は `Clip.hslMask`(省くと nil)。
/// 形のマスク(`ProjectModel+Mask`)と同じ作法: つまみのドラッグは 1 回の Undo。
extension ProjectModel {
    nonisolated static let hslMaskUndoName = "HSLマスクの変更"

    /// オン(既定のマスク)・オフ(nil に戻す)・反転やプレビューなどの離散的な変更。1 回の Undo。
    func setHSLMask(_ mask: HSLMask?, clipId: String? = nil, name: String = ProjectModel.hslMaskUndoName) {
        setClipProperty({ $0.hslMask = mask }, name: name, clipId: clipId)
    }

    /// 選択の 1 項目だけ変える(マスクが無ければ既定から作る)。1 回の Undo。
    func setHSLMaskField(clipId: String, name: String = ProjectModel.hslMaskUndoName, _ change: @escaping (inout HSLMask) -> Void) {
        setClipProperty({ c in
            var m = c.hslMask ?? HSLMask()
            change(&m)
            c.hslMask = m
        }, name: name, clipId: clipId)
    }

    /// スライダーのドラッグ中(`beginGesture` 〜 `commitGesture`)。形のマスクの `liveMaskField` と同じ作法。
    func liveHSLMaskField(clipId: String, _ change: @escaping (inout HSLMask) -> Void) {
        guard !isLocked, let c = clip(clipId) else { return }
        var p = gestureBase ?? project
        guard let loc = ClipEditing.locate(c.id, in: p) else { return }
        var m = p.tracks[loc.track].clips[loc.index].hslMask ?? HSLMask()
        change(&m)
        p.tracks[loc.track].clips[loc.index].hslMask = m
        if gestureBase != nil { updateGesture(p) } else if p != project { edit(Self.hslMaskUndoName) { $0 = p } }
    }
}
