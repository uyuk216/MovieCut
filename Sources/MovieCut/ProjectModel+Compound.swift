import Foundation
import MovieCutCore

/// 複合クリップ(メニュー ▸ クリップ ▸ 複合クリップにまとめる / 複合クリップを解除)。まとめ・解除の計算は MovieCutCore の `CompoundEditing`。
/// ここは Undo(1 操作 = 1 回)と選択だけ。
extension ProjectModel {
    static let compoundGroupUndoName = "複合クリップにまとめる"
    static let compoundUngroupUndoName = "複合クリップを解除"

    /// 選んだクリップ(2 つ以上)を 1 つの複合クリップにまとめる。まとめた複合クリップを選ぶ。1 回の Undo。
    @discardableResult
    func groupSelectedCompound() -> Bool {
        guard !isLocked else { return false }
        let ids = LayerEditing.editableIds(selectedClipIDs, in: project)
        guard ids.count >= 2 else { statusText = "複合クリップにまとめるには、2 つ以上のクリップを選んでください"; return false }
        guard let r = CompoundEditing.group(project, clipIds: Array(ids)) else {
            statusText = "まとめられません(ロックされたレイヤー、深すぎる入れ子、循環のいずれか)"
            return false
        }
        flushCoalesced()
        guard edit(Self.compoundGroupUndoName, { $0 = r.project }) else { return false }
        selectOnly(r.compoundId)
        return true
    }

    /// 選んでいる複合クリップを解除する(中身を元のレイヤーへ戻し、戻したクリップを選ぶ)。1 回の Undo。
    @discardableResult
    func ungroupSelectedCompound() -> Bool {
        guard !isLocked, let id = selectedClipId, let c = clip(id), CompoundEditing.supports(c) else { return false }
        guard let r = CompoundEditing.ungroup(project, clipId: id) else {
            statusText = "解除できません(戻す先のレイヤーがロックされています)"
            return false
        }
        flushCoalesced()
        guard edit(Self.compoundUngroupUndoName, { $0 = r.project }) else { return false }
        setSelection(ClipSelection(ids: Set(r.clipIds), primary: r.clipIds.first))
        return true
    }
}
