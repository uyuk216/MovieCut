import Foundation
import MovieCutCore

/// トラックミキサー(出力 ▸ トラックミキサー…)の編集。レイヤー単位の音量・パン・消音・ソロ・リセット。
/// 音量・パンのスライダーは、ドラッグ中は `liveTrackVolume` / `liveTrackPan`(Undo に積まない)で動かし、離したときに `commitGesture` で 1 回にまとめる。
extension ProjectModel {
    static let trackVolumeUndoName = "レイヤーの音量"
    static let trackPanUndoName = "レイヤーのパン"

    /// 音量(線形 0〜2)。1 操作 = 1 回の Undo。変わらなければ false。
    @discardableResult
    func setTrackVolume(_ index: Int, _ volume: Double) -> Bool {
        guard !isLocked, let p = LayerEditing.setTrackVolume(in: project, index: index, volume) else { return false }
        return edit(Self.trackVolumeUndoName) { $0 = p }
    }

    /// パン(-1〜1)。1 操作 = 1 回の Undo。変わらなければ false。
    @discardableResult
    func setTrackPan(_ index: Int, _ pan: Double) -> Bool {
        guard !isLocked, let p = LayerEditing.setTrackPan(in: project, index: index, pan) else { return false }
        return edit(Self.trackPanUndoName) { $0 = p }
    }

    /// ドラッグ中の音量(Undo に積まない)。ドラッグ(`beginGesture` 〜 `commitGesture`)の最中なら Undo に積まず、
    /// そうでなければ(キーボードや VoiceOver でスライダーを動かしたときなど)1 回の編集にする
    /// (`liveClipProperty` と同じ約束。ジェスチャの外で `updateGesture` に渡すと、変更が黙って捨てられてつまみが元の値へ戻る)。
    func liveTrackVolume(_ index: Int, _ volume: Double) {
        guard let p = LayerEditing.setTrackVolume(in: project, index: index, volume) else { return }
        if gestureBase != nil { updateGesture(p) } else { edit(Self.trackVolumeUndoName) { $0 = p } }
    }

    /// ドラッグ中のパン(Undo に積まない)。ジェスチャの外では 1 回の編集にする(`liveTrackVolume` と同じ)。
    func liveTrackPan(_ index: Int, _ pan: Double) {
        guard let p = LayerEditing.setTrackPan(in: project, index: index, pan) else { return }
        if gestureBase != nil { updateGesture(p) } else { edit(Self.trackPanUndoName) { $0 = p } }
    }

    /// ミュートの切り替え。
    @discardableResult
    func toggleTrackMuted(_ index: Int) -> Bool {
        guard !isLocked, project.tracks.indices.contains(index),
              let p = LayerEditing.setMuted(in: project, index: index, !project.tracks[index].isMuted) else { return false }
        return edit("レイヤーの消音") { $0 = p }
    }

    /// ソロの切り替え(レイヤー欄のソロと同じ編集)。
    @discardableResult
    func toggleTrackSolo(_ index: Int) -> Bool {
        toggleLayerSolo(index)
    }

    /// このレイヤーの音量・パン・消音・ソロを標準に戻す。
    @discardableResult
    func resetTrackMix(_ index: Int) -> Bool {
        guard !isLocked, let p = LayerEditing.resetTrackMix(in: project, index: index) else { return false }
        return edit("レイヤーのミックスをリセット") { $0 = p }
    }
}
