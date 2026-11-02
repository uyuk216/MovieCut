import MovieCutCore

/// 「字幕を追加…」: 再生位置に字幕を足す(または選んだ文字クリップの文を直す)。1 回の Undo。ロジックは Core の `SubtitleQuickAdd`。
extension ProjectModel {
    /// メニューから開く。ロック中は開かない。文字クリップを選んでいても、そのレイヤー・クリップがロックされていれば直す対象にしない(新しく足す)。
    func openSubtitleSheet() {
        guard !isLocked else { return }
        if let c = selectedClip, c.type == .text, !LayerEditing.isLockedClip(c.id, in: project) {
            subtitleSheetTargetId = c.id
        } else {
            subtitleSheetTargetId = nil
        }
        showSubtitleSheet = true
    }

    /// シートの決定。本文が空なら何もせず false(シートは開いたまま)。成功したらシートを閉じる。
    @discardableResult
    func commitSubtitleSheet(text: String, duration: Double) -> Bool {
        guard !isLocked else { return false }
        let style = TextStyleLibrary.builtins.first { $0.id == "builtin.classic" }?.look
        if let id = subtitleSheetTargetId {
            guard let p = SubtitleQuickAdd.updateText(clipId: id, text: text, duration: duration, in: project) else { return false }
            edit("字幕の編集") { $0 = p }
            statusText = "字幕を直しました"
        } else {
            guard let r = SubtitleQuickAdd.add(text: text, at: currentTime, duration: duration, style: style, to: project) else { return false }
            edit("字幕の追加") { $0 = r.project }
            selectedClipId = r.clipId
            statusText = "再生位置に字幕を追加しました"
        }
        showSubtitleSheet = false
        subtitleSheetTargetId = nil
        return true
    }
}
