import Foundation
import MovieCutCore

/// 音量包絡線のタイムライン編集(監査 #64 / W3-23)。
/// 計算は MovieCutCore の VolumeEnvelopeEditing に任せ、ここは Undo・選択だけを担う。
/// 追加・削除は 1 回の Undo、ドラッグは beginGesture〜commitGesture で 1 回の Undo にまとめる
/// (キーフレームの菱形ドラッグと同じ作法)。
extension ProjectModel {
    /// 包絡線の undo 名。
    static let volumeEnvelopeUndoName = "音量包絡線の変更"

    /// 点を足す(1 回の Undo)。足した点の番号を返す。
    @discardableResult
    func addVolumePoint(clipId: String, at t: Double, gain v: Double) -> Int? {
        guard !isLocked, let c = clip(clipId), VolumeEnvelopeEditing.supports(c) else { return nil }
        var probe = c
        guard let idx = VolumeEnvelopeEditing.addPoint(&probe, at: t, gain: v) else { return nil }
        setClipProperty({ _ = VolumeEnvelopeEditing.addPoint(&$0, at: t, gain: v) }, name: Self.volumeEnvelopeUndoName, clipId: clipId)
        return idx
    }

    /// 点を消す(1 回の Undo)。
    @discardableResult
    func removeVolumePoint(clipId: String, index: Int) -> Bool {
        guard !isLocked, let c = clip(clipId) else { return false }
        var probe = c
        guard VolumeEnvelopeEditing.removePoint(&probe, index: index) else { return false }
        setClipProperty({ _ = VolumeEnvelopeEditing.removePoint(&$0, index: index) }, name: Self.volumeEnvelopeUndoName, clipId: clipId)
        return true
    }

    /// 点をドラッグした先の Project(ドラッグ中の `updateGesture` 用)。`base` から作り直す。
    func projectMovingVolumePoint(base: Project, clipId: String, index: Int, toTime t: Double, gain v: Double) -> Project? {
        guard let loc = ClipEditing.locate(clipId, in: base) else { return nil }
        var p = base
        var c = p.tracks[loc.track].clips[loc.index]
        guard VolumeEnvelopeEditing.movePoint(&c, index: index, toTime: t, gain: v) else { return nil }
        p.tracks[loc.track].clips[loc.index] = c
        return p
    }
}
