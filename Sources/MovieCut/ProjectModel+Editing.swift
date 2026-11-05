import Foundation
import AppKit
import UniformTypeIdentifiers
import MovieCutCore

/// タイムライン編集(M4a)。メニュー(M5)からもそのまま呼べるよう、UI に依存しない形で model に置く。
extension ProjectModel {
    var selectedClip: Clip? {
        guard let id = selectedClipId else { return nil }
        return project.allClips.first { $0.id == id }
    }

    /// 選択中のクリップの中に再生ヘッドがある(端は含まない)= 分割できる。
    var canSplit: Bool {
        guard let c = selectedClip else { return false }
        return currentTime > c.start && currentTime < c.start + c.duration
    }

    // MARK: 分割 / 削除

    /// S: 選択中のクリップを再生ヘッドで分割する(左が選択のまま)。できたら true。
    @discardableResult
    func splitSelected() -> Bool {
        guard let id = selectedClipId, !isLocked,
              let r = ClipEditing.split(in: project, clipId: id, at: currentTime) else { return false }
        return edit("クリップの分割") { $0 = r.project }
    }

    /// Delete: 選択中のクリップ(複数なら全部)を消して選択を外す。1 回の Undo。できたら true。
    /// ロックされたレイヤーのクリップは消さない(選択に残す)。
    @discardableResult
    func deleteSelected() -> Bool {
        guard !selectedClipIDs.isEmpty, !isLocked else { return false }
        let ids = LayerEditing.editableIds(selectedClipIDs, in: project)
        guard !ids.isEmpty else { statusText = Self.lockedNotice; return false }
        guard let p = ClipEditing.delete(in: project, clipIds: ids) else { return false }
        guard edit("クリップの削除", { $0 = p }) else { return false }
        deselectRemoving(ids)
        return true
    }

    // MARK: 追加

    /// 素材を再生ヘッド(または `at`)に 1 つずつ置く。対応しない拡張子は無視。全体で 1 回の Undo、最後に置いたものを選択。
    /// 置いたクリップの id を返す。
    @discardableResult
    func addMedia(urls allUrls: [URL], at time: Double? = nil) async -> [String] {
        guard !isLocked else { return [] }
        let psds = allUrls.filter { PSDImporter.isPSD(path: $0.path) }
        let urls = allUrls.filter { !PSDImporter.isPSD(path: $0.path) }
        if !psds.isEmpty {
            let psdIds = await importPSDFiles(urls: psds, at: time)
            if urls.isEmpty { return psdIds }
        }
        let files = urls.filter { ClipEditing.isSupportedMedia(path: $0.path) }
        guard !files.isEmpty else { return [] }
        var media: [(path: String, kind: ClipType, duration: Double)] = []
        for u in files {
            let kind = ClipEditing.kindOf(path: u.path)
            media.append((u.path, kind, await ClipEditing.probeDuration(url: u, kind: kind)))
        }
        let t = max(0, time ?? currentTime)
        var ids: [String] = []
        edit("素材の追加") { p in ids = ClipEditing.place(media: media, at: t, in: &p); UnusedMedia.register(media.map(\.path), in: &p) }
        selectedClipId = ids.last
        statusText = "\(ids.count) 個の素材を追加しました"
        return ids
    }

    /// タイムラインへのドロップ(Finder・素材ブラウザ共通): 落とした時刻を吸着して、落とした行のレイヤーへ置く。
    /// 置けないときは `ClipEditing.place` と同じく空いている最初のレイヤー(無ければ新しいレイヤー)へ。1 回の取り消し。
    @discardableResult
    func dropMedia(urls allUrls: [URL], dropTime: Double, rowIndex: Int?) async -> [String] {
        guard !isLocked else { return [] }
        let psds = allUrls.filter { PSDImporter.isPSD(path: $0.path) }
        let urls = allUrls.filter { !PSDImporter.isPSD(path: $0.path) }
        if !psds.isEmpty {
            let psdIds = await importPSDFiles(urls: psds, at: dropTime)
            if urls.isEmpty { return psdIds }
        }
        let files = urls.filter { ClipEditing.isSupportedMedia(path: $0.path) }
        guard !files.isEmpty else { return [] }
        var media: [(path: String, kind: ClipType, duration: Double)] = []
        for u in files {
            let kind = ClipEditing.kindOf(path: u.path)
            media.append((u.path, kind, await ClipEditing.probeDuration(url: u, kind: kind)))
        }
        let place = TimelineDrop.placement(dropTime: dropTime, duration: media[0].duration, rowIndex: rowIndex, project: project,
                                           playhead: currentTime, pps: pps, snapEnabled: snapEnabled)
        var ids: [String] = []
        edit("素材のドロップ") { p in ids = ClipEditing.place(media: media, at: place.start, preferredTrack: place.track, in: &p); UnusedMedia.register(media.map(\.path), in: &p) }
        guard !ids.isEmpty else { return [] }
        selectedClipId = ids.last
        statusText = "\(ids.count) 個の素材を追加しました"
        return ids
    }

    /// 「テキスト」ボタン: 一番上のレイヤーの再生ヘッド位置に 3 秒の文字を足して選択する。
    @discardableResult
    func addTextClip() -> String? {
        guard !isLocked else { return nil }
        let c = ClipEditing.makeTextClip(at: currentTime, project: project)
        edit("テキストの追加") { ClipEditing.appendToTopLayer(c, in: &$0) }
        selectedClipId = c.id
        return c.id
    }

    /// 「ぼかし範囲」ボタン。
    @discardableResult
    func addBlurClip() -> String? {
        guard !isLocked else { return nil }
        let c = ClipEditing.makeBlurClip(at: currentTime, project: project)
        edit("ぼかし範囲の追加") { ClipEditing.appendToTopLayer(c, in: &$0) }
        selectedClipId = c.id
        return c.id
    }

    /// 「調整レイヤー」(メニュー ▸ クリップ): 一番上のレイヤーの再生ヘッド位置に 3 秒の調整レイヤーを足して選択する。
    @discardableResult
    func addAdjustmentClip() -> String? {
        guard !isLocked else { return nil }
        let c = ClipEditing.makeAdjustmentClip(at: currentTime, project: project)
        edit("調整レイヤーの追加") { ClipEditing.appendToTopLayer(c, in: &$0) }
        selectedClipId = c.id
        return c.id
    }

    /// 「音声ビジュアライザを追加」(メニュー ▸ クリップ): 一番上のレイヤーの再生ヘッド位置に 3 秒のビジュアライザを足して選択する。
    @discardableResult
    func addVisualizerClip() -> String? {
        guard !isLocked else { return nil }
        let c = ClipEditing.makeVisualizerClip(at: currentTime, project: project)
        edit("ビジュアライザの追加") { ClipEditing.appendToTopLayer(c, in: &$0) }
        selectedClipId = c.id
        return c.id
    }

    /// 「図形を追加」(メニュー ▸ クリップ ▸ 図形を追加): 一番上のレイヤーの再生ヘッド位置に 3 秒の図形を足して選択する。
    @discardableResult
    func addShapeClip(kind: FigureKind) -> String? {
        guard !isLocked else { return nil }
        let c = ClipEditing.makeShapeClip(kind, at: currentTime, project: project)
        edit("図形の追加") { ClipEditing.appendToTopLayer(c, in: &$0) }
        selectedClipId = c.id
        return c.id
    }

    /// クリップ ▸ 1 コマ前へ / 後ろへ動かす: 選んでいるクリップを動かす。1 回で元に戻せる。動かせなければ何もしない。
    @discardableResult
    func nudgeSelectedClips(frames: Int) -> Bool {
        guard !isLocked, let p = ClipNudge.nudge(in: project, clipIds: selectedClipIDs, frames: frames) else { return false }
        return edit(frames < 0 ? "1 コマ前へ動かす" : "1 コマ後ろへ動かす") { $0 = p }
    }

    /// 「スタンプを追加」(メニュー ▸ クリップ ▸ スタンプを追加): 一番上のレイヤーの再生ヘッド位置に 3 秒のスタンプを足して選択する。
    @discardableResult
    func addStampClip(emoji: String) -> String? {
        guard !isLocked, StampCatalog.isStamp(emoji) else { return nil }
        let c = ClipEditing.makeStampClip(emoji, at: currentTime)
        edit("スタンプの追加") { ClipEditing.appendToTopLayer(c, in: &$0) }
        selectedClipId = c.id
        return c.id
    }

    /// 「素材を追加」: ファイルを選ぶパネルを出して、選んだものを置く。
    func chooseAndAddMedia() {
        guard !isLocked else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = (ClipEditing.mediaExtensions + ["psd"]).compactMap { UTType(filenameExtension: $0) }
        panel.title = "素材を追加"
        let run: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            guard resp == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in await self?.addMedia(urls: urls) }
        }
        if let w = window { panel.beginSheetModal(for: w, completionHandler: run) } else { panel.begin(completionHandler: run) }
    }

    // MARK: ドラッグ中の編集(Undo は離したときに 1 回だけ)

    /// ドラッグ開始: 再生を止め、いまのプロジェクトを覚える。
    func beginGesture() {
        playback.pause()
        gestureBase = project
    }

    /// ドラッグ中: Undo に登録せずに差し替える(プレビューは model.project を見ているのでそのまま追従する)。
    func updateGesture(_ p: Project) {
        guard let base = gestureBase, p != project else { return }
        if LayerEditing.violatesLock(old: base, new: p) { return }   // ロックされたレイヤーのクリップは動かさない
        project = p
        playback.projectDidChange()
    }

    /// ドラッグ終了: 何か変わっていれば 1 回の Undo として登録する。変わっていなければ何も登録しない。
    func commitGesture(_ name: String) {
        guard let base = gestureBase else { return }
        gestureBase = nil
        let current = project
        guard current != base else { return }
        project = base                       // 一度、ドラッグ前に戻してから
        edit(name) { $0 = current }          // 1 つの編集として入れ直す(Undo は base に戻る)
    }
}
