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

extension ProjectModel {
    /// 選んでいるクリップが属するグループ(出てくる順)。
    var selectionGroupIds: [String] {
        var out: [String] = []
        for c in project.allClips where selectedClipIDs.contains(c.id) {
            if let g = c.group, !out.contains(g) { out.append(g) }
        }
        return out
    }

    /// そのグループの全員が無効化されているか(プロパティ欄の表示用)。
    func groupAllDisabled(_ group: String) -> Bool { ClipGrouping.allDisabled(group, in: project) }

    /// 選択をグループ全員に広げたとき、全員が無効化されているか(メニューのラベル用)。
    var selectionGroupAllDisabled: Bool {
        let ids = ClipGrouping.expand(selectedClipIDs, in: project)
        let members = project.allClips.filter { ids.contains($0.id) }
        return !members.isEmpty && members.allSatisfy { $0.isDisabled }
    }

    /// グループの有効/無効をまとめて切り替える(選択中のクリップのグループ全員が対象)。
    /// 全員が無効なら有効に、そうでなければ全員を無効にする。ロックされたレイヤー・クリップは変えない。1 回の Undo。
    @discardableResult
    func toggleGroupDisabledSelected() -> Bool {
        guard !isLocked, selectionHasGroup else { return false }
        let expanded = ClipGrouping.expand(selectedClipIDs, in: project)
        let ids = LayerEditing.editableIds(expanded, in: project)
        guard !ids.isEmpty else { statusText = Self.lockedNotice; return false }
        let on = !selectionGroupAllDisabled
        var p = project
        let changed = ClipGrouping.setDisabled(ids: ids, on: on, in: &p)
        guard changed > 0 else { return false }
        let ok = edit(on ? "グループを無効にする" : "グループを有効にする") { $0 = p }
        if ok { statusText = on ? "グループの \(changed) 個のクリップを無効にしました" : "グループの \(changed) 個のクリップを有効にしました" }
        return ok
    }

    /// グループを複合クリップにまとめる(YMM4 グループ制御の「画像を合成」の相当。
    /// 合成そのものは複合クリップの描画経路が担当し、グループは「緩い束」のまま別に残る)。
    /// 選択をグループ全員に広げてから、既存の複合化を使う。1 回の Undo。
    @discardableResult
    func compoundSelectedGroup() -> Bool {
        guard !isLocked, selectionHasGroup else { return false }
        let expanded = ClipGrouping.expand(selectedClipIDs, in: project)
        if expanded != selectedClipIDs {
            setSelection(ClipSelection(ids: expanded, primary: selectedClipId))
        }
        return groupSelectedCompound()
    }
}
