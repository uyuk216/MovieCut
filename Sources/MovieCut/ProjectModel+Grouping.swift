import Foundation
import MovieCutCore

/// クリップのグループ化の画面操作。計算は MovieCutCore の `ClipGrouping`(純粋関数)に任せ、
/// ここは Undo・選択・状態欄だけ。グループのクリップをタイムラインで押すと全員が選ばれ、
/// そのままドラッグするとまとめて動く(複数選択の移動と同じ経路)。
extension ProjectModel {
    /// 選んでいるクリップを 1 つのグループにする(2 つ以上)。1 回の Undo。
    @discardableResult
    func groupSelectedClips() -> Bool {
        guard !isLocked, selectedClipIDs.count >= 2 else { return false }
        var p = project
        ClipGrouping.assign(ClipGrouping.nextId(in: p), to: selectedClipIDs, in: &p)
        guard p != project else { return false }
        let ok = edit("クリップのグループ化") { $0 = p }
        if ok { statusText = "\(selectedClipIDs.count) 個のクリップをグループにしました" }
        return ok
    }

    /// 選んでいるクリップのグループを外す(グループの無いクリップだけなら何もしない)。1 回の Undo。
    @discardableResult
    func ungroupSelectedClips() -> Bool {
        guard !isLocked, !selectedClipIDs.isEmpty else { return false }
        var p = project
        ClipGrouping.assign(nil, to: selectedClipIDs, in: &p)
        guard p != project else { return false }
        return edit("グループの解除") { $0 = p }
    }

    /// 選んでいるクリップの中に、グループに入っているものがあるか(解除ボタンの有効・無効)。
    var selectionHasGroup: Bool {
        project.allClips.contains { selectedClipIDs.contains($0.id) && $0.group != nil }
    }

    /// そのクリップと同じグループのクリップを全部選ぶ。
    func selectGroupMembers(of clipId: String) {
        guard let c = clip(clipId), c.group != nil else { return }
        setSelection(ClipSelection(ids: ClipGrouping.expand([clipId], in: project), primary: clipId))
    }

    /// タイムラインのクリック用: グループのクリップなら全員を選ぶ(ドラッグでまとめて動かせる)。
    /// そうでなければ単一選択。⌘・⇧クリックの手動の選択には使わない。
    func selectExpandingGroup(_ id: String) {
        if let c = clip(id), c.group != nil { selectGroupMembers(of: id) } else { selectOnly(id) }
    }
}
