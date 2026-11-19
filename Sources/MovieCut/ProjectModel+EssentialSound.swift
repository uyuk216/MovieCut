import Foundation
import MovieCutCore

/// エッセンシャルサウンド(種別タグと種別ごとの整音プリセット)。
/// 計算は MovieCutCore の `EssentialSoundEditing` / `ClipEditing` に任せ、
/// ここは Undo(1 操作 = 1 回)だけ。何も変わらない操作は Undo に積まない。
extension ProjectModel {
    static let audioCategoryUndoName = "音の種類の変更"
    static let essentialSoundUndoName = "エッセンシャルサウンドの整音"

    /// 種別タグだけを付ける / 外す(整音はしない)。1 回の Undo。
    @discardableResult
    func setAudioCategory(clipId: String, _ category: AudioCategory?) -> Bool {
        guard !isLocked, let p = ClipEditing.setAudioCategory(in: project, clipId: clipId, category) else { return false }
        flushCoalesced()
        return edit(Self.audioCategoryUndoName) { $0 = p }
    }

    /// そのクリップの種別の整音プリセットを適用する(タグ + エフェクト一式)。全体で 1 回の Undo。
    @discardableResult
    func applyEssentialSound(clipId: String) -> Bool {
        guard !isLocked, let p = ClipEditing.applyEssentialSound(in: project, ids: [clipId]) else { return false }
        flushCoalesced()
        return edit(Self.essentialSoundUndoName) { $0 = p }
    }
}
