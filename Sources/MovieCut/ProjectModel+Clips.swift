import Foundation
import AppKit
import MovieCutCore

/// M7: クリップメニュー・移動メニュー(マーカー含む)の操作。ロジックは MovieCutCore の純粋関数に任せ、ここは Undo と選択・再生位置だけ。
extension ProjectModel {
    // MARK: クリップ

    /// 「クリップを複製」(⌘D): 元のすぐ後ろ(重なるなら空いているレイヤー)へ。複製を選択する。1 回の Undo。
    @discardableResult
    func duplicateSelected() -> Bool {
        guard let id = selectedClipId, !isLocked, let r = ClipEditing.duplicate(in: project, clipId: id) else { return false }
        edit("クリップの複製") { $0 = r.project }
        selectedClipId = r.newId
        return true
    }

    /// 「再生位置より前を切り落とす」(⌥⌘[)。
    @discardableResult
    func trimSelectedBeforePlayhead() -> Bool {
        guard let id = selectedClipId, !isLocked, let p = ClipEditing.trimBefore(in: project, clipId: id, at: currentTime) else { return false }
        edit("再生位置より前を切り落とす") { $0 = p }
        return true
    }

    /// 「再生位置より後ろを切り落とす」(⌥⌘])。
    @discardableResult
    func trimSelectedAfterPlayhead() -> Bool {
        guard let id = selectedClipId, !isLocked, let p = ClipEditing.trimAfter(in: project, clipId: id, at: currentTime) else { return false }
        edit("再生位置より後ろを切り落とす") { $0 = p }
        return true
    }

    /// 「すき間を詰めて削除」(⌥⌘⌫): 同じレイヤーの後ろのクリップを左へ詰める。選択は外れる。
    @discardableResult
    func rippleDeleteSelected() -> Bool {
        guard let id = selectedClipId, !isLocked, let p = ClipEditing.rippleDelete(in: project, clipId: id) else { return false }
        edit("すき間を詰めて削除") { $0 = p }
        selectedClipId = nil
        return true
    }

    /// 「前のクリップを選択」「次のクリップを選択」(開始時刻順・全レイヤー)。選んだら true。
    @discardableResult
    func selectAdjacentClip(forward: Bool) -> Bool {
        guard !isLocked, let id = ClipEditing.adjacentClipId(in: project, from: selectedClipId, forward: forward, playhead: currentTime) else { return false }
        selectedClipId = id   // タイムラインが行を見える所までスクロールする
        return true
    }

    /// 「選択クリップを上(下)のレイヤーへ」: 時刻はそのまま。`up` は画面の上の行(= 配列の一つ前)。
    @discardableResult
    func moveSelectedToAdjacentLayer(up: Bool) -> Bool {
        guard let id = selectedClipId, !isLocked, let p = ClipEditing.moveToAdjacentLayer(in: project, clipId: id, delta: up ? -1 : 1) else { return false }
        edit(up ? "上のレイヤーへ移動" : "下のレイヤーへ移動") { $0 = p }
        return true
    }

    /// 「選択クリップの音声を作り直す」(⌥⌘R): ボイスクリップのときだけ。
    func regenerateSelectedVoice() async {
        guard let c = selectedClip, c.type == .voice, !isLocked else { return }
        _ = await regenerateVoice(clipId: c.id)
    }

    // MARK: 移動

    /// 最後(プロジェクトの終わり)へ。
    func goToEnd() { playback.seek(to: project.endTime) }

    /// 前後の編集点(全レイヤーのクリップの頭と終わり・0・終わり)へ。動いたら true。
    @discardableResult
    func seekEditPoint(forward: Bool) -> Bool {
        let pts = ClipEditing.editPoints(project)
        guard let t = forward ? ClipEditing.nextPoint(pts, after: currentTime) : ClipEditing.previousPoint(pts, before: currentTime) else { return false }
        playback.seek(to: t)
        return true
    }

    /// 前後のセリフ(ボイスクリップの頭)へ。
    @discardableResult
    func seekVoiceLine(forward: Bool) -> Bool {
        let pts = ClipEditing.voiceStarts(project)
        guard let t = forward ? ClipEditing.nextPoint(pts, after: currentTime) : ClipEditing.previousPoint(pts, before: currentTime) else { return false }
        playback.seek(to: t)
        return true
    }

    /// 「時間を指定して移動…」のシートを開く。
    func openJumpSheet() { if !isLocked { showJumpSheet = true } }

    /// シートの決定: 文字を時刻にして [0, 終わり] に収めて移動し、シートを閉じる。読めなければ false(シートはそのまま)。
    @discardableResult
    func commitJump(_ text: String) -> Bool {
        guard let t = ClipEditing.parseTimecode(text) else { return false }
        playback.seek(to: ClipEditing.clampJump(t, end: project.endTime))
        showJumpSheet = false
        return true
    }

    // MARK: マーカー

    /// マーカーとみなす近さ(1 コマ)。
    var markerTolerance: Double { project.frameRate.frameDuration }

    /// 再生位置の(1 コマ以内の)マーカー。
    var markerNearPlayhead: Marker? {
        MarkerEditing.nearest(in: project, to: currentTime, tolerance: markerTolerance)
    }

    /// 「マーカーを追加」(⌃⌘M): 再生位置に「マーカーN」。同じ場所にもう在るときは足さない。
    @discardableResult
    func addMarkerAtPlayhead() -> String? {
        guard !isLocked, markerNearPlayhead == nil else { return nil }
        let r = MarkerEditing.add(in: project, at: currentTime)
        edit("マーカーの追加") { $0 = r.project }
        return r.id
    }

    /// 「マーカーを名前変更…」: 再生位置のマーカーの名前を変えるシートを出す。
    func openRenameMarker() {
        guard !isLocked, let m = markerNearPlayhead else { return }
        renamingMarkerId = m.id
    }

    @discardableResult
    func renameMarker(id: String, to name: String) -> Bool {
        guard !isLocked, let p = MarkerEditing.rename(in: project, id: id, to: name) else { return false }
        edit("マーカーの名前変更") { $0 = p }
        return true
    }

    /// 「マーカーを削除」: 再生位置(1 コマ以内)のマーカー。
    @discardableResult
    func deleteMarkerAtPlayhead() -> Bool {
        guard !isLocked, let m = markerNearPlayhead, let p = MarkerEditing.remove(in: project, id: m.id) else { return false }
        edit("マーカーの削除") { $0 = p }
        return true
    }

    /// 「すべてのマーカーを消去」。
    @discardableResult
    func clearMarkers() -> Bool {
        guard !isLocked, !project.markers.isEmpty else { return false }
        edit("すべてのマーカーを消去") { $0.markers = [] }
        return true
    }

    /// 前後のマーカーへ。
    @discardableResult
    func seekMarker(forward: Bool) -> Bool {
        guard let m = forward ? MarkerEditing.next(in: project, after: currentTime) : MarkerEditing.previous(in: project, before: currentTime) else { return false }
        playback.seek(to: m.time)
        return true
    }

    /// マーカー一覧の項目 / ルーラーの旗のクリック: そこへ移動。
    @discardableResult
    func jumpToMarker(id: String) -> Bool {
        guard let m = project.markers.first(where: { $0.id == id }) else { return false }
        playback.seek(to: m.time)
        return true
    }
}
