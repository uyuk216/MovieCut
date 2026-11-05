import MovieCutCore

/// ロール編集 / スリップ編集 / トラックターゲットのモデル側。計算は Core の `ClipRollSlip` / `TrackTarget`。どれも 1 回の Undo、変わらなければ何も登録しない。
extension ProjectModel {
    /// 選んでいるクリップ 1 つに対する、ロールの (左, 右)。選択が 1 つでないときは nil。
    var rollBoundary: (left: String, right: String)? {
        guard selectedClipIDs.count <= 1, let id = selectedClipId else { return nil }
        return ClipRollSlip.boundary(for: id, in: project)
    }

    var canRoll: Bool {
        guard !isLocked, let id = selectedClipId, selectedClipIDs.count <= 1 else { return false }
        return ClipRollSlip.rollBlockedReason(in: project, clipId: id) == nil
    }

    var canSlip: Bool {
        guard !isLocked, let id = selectedClipId, selectedClipIDs.count <= 1 else { return false }
        return ClipRollSlip.slipBlockedReason(in: project, clipId: id) == nil
    }

    func openRollSheet() { if canRoll { showRollSheet = true } }
    func openSlipSheet() { if canSlip { showSlipSheet = true } }

    /// 選択クリップの境界を `frames` コマ動かす(正 = 後ろへ)。動かせなければ false(Undo に載せない)。
    @discardableResult
    func rollSelected(frames: Int) -> Bool {
        guard !isLocked, let b = rollBoundary else { return false }
        guard let p = ClipRollSlip.roll(in: project, leftClipId: b.left, frames: frames) else {
            if LayerEditing.isLockedClip(b.left, in: project) || LayerEditing.isLockedClip(b.right, in: project) { statusText = Self.lockedNotice }
            return false
        }
        return edit("ロール編集") { $0 = p }
    }

    /// 選択クリップの素材の区間を `frames` コマずらす(正 = 後ろの素材へ)。
    @discardableResult
    func slipSelected(frames: Int) -> Bool {
        guard !isLocked, let id = selectedClipId, selectedClipIDs.count <= 1 else { return false }
        guard let p = ClipRollSlip.slip(in: project, clipId: id, frames: frames) else {
            if LayerEditing.isLockedClip(id, in: project) { statusText = Self.lockedNotice }
            return false
        }
        return edit("スリップ編集") { $0 = p }
    }

    // MARK: トラックターゲット

    /// レイヤーのターゲット印を付け替える(付いていれば外す)。
    @discardableResult
    func toggleTrackTarget(_ index: Int) -> Bool {
        guard !isLocked, let p = TrackTarget.toggle(in: project, index: index) else { return false }
        return edit("トラックターゲットの切り替え") { $0 = p }
    }
}
