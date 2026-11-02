import Foundation
import AppKit
import MovieCutCore

/// A6: 複数選択・コピー / 切り取り / 貼り付け・レイヤーの操作。ロジックは MovieCutCore の純粋関数に任せ、ここは Undo と選択・ペーストボードだけ。
extension ProjectModel {
    /// 一般のペーストボードに書くときの種類(このアプリ専用。別のウィンドウ・別のドキュメントへ貼れる)。
    static let clipPasteboardType = NSPasteboard.PasteboardType("jp.local.moviecut.clips")

    // MARK: 選択

    var selection: ClipSelection { ClipSelection(ids: selectedClipIDs, primary: selectedClipId) }
    var isMultiSelection: Bool { selectedClipIDs.count > 1 }

    /// 選択をまとめて入れ替える(主を含まない集合は、主を開始の一番早いものにする)。
    func setSelection(_ s: ClipSelection) {
        var ids = s.ids
        var primary = s.primary
        if let p = primary { ids.insert(p) }
        else if !ids.isEmpty { primary = TimelineSelection.fallbackPrimary(ids, in: project) }
        selectedClipIDs = ids                 // 先に集合を入れる(主の didSet が、含まれていれば単一選択に戻さない)
        selectedClipId = primary
    }

    /// 単一選択にする(nil なら外す)。
    func selectOnly(_ id: String?) {
        selectedClipIDs = id.map { [$0] } ?? []
        selectedClipId = id
    }

    /// 消したクリップを選択から外す。残りがあれば残りを選び、無ければ全部外す。
    func deselectRemoving(_ ids: Set<String>) {
        let rest = selectedClipIDs.subtracting(ids)
        if rest.isEmpty { selectedClipId = nil; return }
        setSelection(TimelineSelection.pruned(ClipSelection(ids: rest, primary: selectedClipId.flatMap { rest.contains($0) ? $0 : nil }), in: project))
    }

    /// 再生位置にあるクリップのうち手前のもの(描画の後ろ・レイヤーの上)を単一選択する。何も無ければ false。
    @discardableResult
    func selectClipAtPlayhead() -> Bool {
        guard let id = TimelineQuery.clipIds(at: currentTime, in: project).last else { return false }
        selectOnly(id)
        return true
    }

    /// 短いクリップ(既定 6 コマ未満)を全部選ぶ。無ければ false。
    @discardableResult
    func selectShortClips() -> Bool {
        let ids = Set(TimelineQuery.shortClipIds(in: project))
        guard !ids.isEmpty else { return false }
        setSelection(ClipSelection(ids: ids, primary: nil))
        return true
    }

    /// 「すべてのクリップを選択」(⌘A はタイムラインにフォーカスがあるとき、responder chain の selectAll: から)。
    @discardableResult
    func selectAllClips() -> Bool {
        let s = TimelineSelection.selectAll(in: project)
        guard !s.ids.isEmpty, s != selection else { return false }
        setSelection(s)
        return true
    }

    // MARK: コピー / 切り取り / 貼り付け

    /// いま貼り付けられるものがあるか(ペーストボードか、アプリ内のコピー)。
    var canPasteClips: Bool { readClipboard() != nil }

    /// 選択を、アプリ内とペーストボードへコピーする。選択に変化はなく、Undo にも積まない。
    @discardableResult
    func copySelection() -> Bool {
        guard let c = ClipClipboard.make(from: project, clipIds: selectedClipIDs) else { return false }
        clipClipboard = c
        if let data = c.encoded() {
            clipPasteboard.clearContents()
            clipPasteboard.setData(data, forType: Self.clipPasteboardType)
        }
        statusText = "\(c.items.count) 個のクリップをコピーしました"
        return true
    }

    /// 切り取り = コピー + 削除(1 回の Undo)。ロックされたレイヤーのクリップはコピーだけして残す。
    @discardableResult
    func cutSelection() -> Bool {
        guard !isLocked, copySelection() else { return false }
        let ids = LayerEditing.editableIds(selectedClipIDs, in: project)
        guard !ids.isEmpty else { statusText = Self.lockedNotice; return true }
        guard let p = ClipEditing.delete(in: project, clipIds: ids) else { return true }
        guard edit("クリップの切り取り", { $0 = p }) else { return true }
        deselectRemoving(ids)
        return true
    }

    private func readClipboard() -> ClipClipboard? {
        if let d = clipPasteboard.data(forType: Self.clipPasteboardType), let c = ClipClipboard.decode(d) { return c }
        return clipClipboard
    }

    /// 貼り付け先のレイヤー: ヘッダーで選んだレイヤー → なければ元のレイヤー(nil)。
    var pasteTargetLayer: Int? {
        guard let i = selectedLayerIndex, project.tracks.indices.contains(i) else { return nil }
        return i
    }

    /// 再生位置に貼り付ける(1 回の Undo)。貼ったクリップを選ぶ。ロックされたレイヤーへは貼らない。
    @discardableResult
    func pasteClips() -> Bool {
        guard !isLocked, let c = readClipboard() else { return false }
        guard let r = ClipEditing.paste(c, in: project, at: currentTime, targetTrack: pasteTargetLayer) else {
            statusText = Self.lockedNotice
            return false
        }
        edit("クリップの貼り付け", enforcesLock: false) { $0 = r.project }
        setSelection(ClipSelection(ids: Set(r.newIds), primary: r.newIds.first))
        statusText = r.skipped > 0 ? "\(r.newIds.count) 個を貼り付けました(ロックされたレイヤーの \(r.skipped) 個は貼りませんでした)" : "\(r.newIds.count) 個のクリップを貼り付けました"
        return true
    }

    // MARK: 移動(複数)

    /// ドラッグ移動の計算(複数選択ならまとめて)。`ids` は押した時点の選択。
    func projectMoving(base: Project, ids: Set<String>, primary: String, deltaT: Double, targetTrack: Int?) -> ClipEditing.Result {
        if ids.count > 1 {
            return ClipEditing.moveMany(in: base, clipIds: ids, primaryId: primary, deltaT: deltaT, targetTrackIndex: targetTrack,
                                        playhead: currentTime, pps: pps, snapEnabled: snapEnabled)
        }
        return ClipEditing.move(in: base, clipId: primary, deltaT: deltaT, targetTrackIndex: targetTrack,
                                playhead: currentTime, pps: pps, snapEnabled: snapEnabled)
    }

    // MARK: レイヤー

    /// メニューの対象のレイヤー: 選んでいるクリップのレイヤー → ヘッダーで選んだレイヤー。
    var targetLayerIndex: Int? {
        if let id = selectedClipId, let loc = ClipEditing.locate(id, in: project) { return loc.track }
        if let i = selectedLayerIndex, project.tracks.indices.contains(i) { return i }
        return nil
    }

    /// ヘッダーを押してレイヤーを選ぶ(クリップの選択は外す)。
    func selectLayer(_ index: Int) {
        guard project.tracks.indices.contains(index) else { return }
        selectedClipId = nil
        selectedLayerIndex = index
    }

    @discardableResult
    func renameLayer(_ index: Int, to name: String) -> Bool {
        guard !isLocked, let p = LayerEditing.rename(in: project, index: index, to: name) else { return false }
        edit("レイヤー名の変更") { $0 = p }
        return true
    }

    /// クリップ ▸ クリップをロック / ロックを解除。選んだクリップが全部ロック済みなら解除、そうでなければ全部ロック。1 回の Undo。
    /// ロック・解除そのものは(クリップ単位のロックには)断られない。ロックされたレイヤーの中では断る。
    @discardableResult
    func toggleClipLockSelected() -> Bool {
        guard !isLocked, !selectedClipIDs.isEmpty else { return false }
        let on = !LayerEditing.allClipsLocked(selectedClipIDs, in: project)
        guard let p = LayerEditing.setClipsLocked(in: project, ids: selectedClipIDs, on) else { return false }
        return edit(on ? "クリップのロック" : "クリップのロック解除") { $0 = p }
    }

    @discardableResult
    func toggleLayerLock(_ index: Int) -> Bool {
        guard !isLocked, project.tracks.indices.contains(index),
              let p = LayerEditing.setLocked(in: project, index: index, !project.tracks[index].isLocked) else { return false }
        edit("レイヤーのロック切り替え") { $0 = p }
        return true
    }

    @discardableResult
    func toggleLayerSolo(_ index: Int) -> Bool {
        guard !isLocked, project.tracks.indices.contains(index),
              let p = LayerEditing.setSolo(in: project, index: index, !project.tracks[index].isSolo) else { return false }
        edit("レイヤーのソロ切り替え") { $0 = p }
        return true
    }

    @discardableResult
    func setLayerHeight(_ index: Int, _ h: LayerHeight) -> Bool {
        guard !isLocked, let p = LayerEditing.setHeight(in: project, index: index, h) else { return false }
        edit("レイヤーの高さ") { $0 = p }
        return true
    }

    // MARK: レイヤーの削除

    /// 削除の確認(クリップがあるとき、またはロックされているときだけ聞く)。true なら消す。テストでは差し替える。
    static var confirmLayerDelete: @MainActor (_ name: String, _ clipCount: Int, _ locked: Bool) -> Bool = { name, count, locked in
        let a = NSAlert()
        a.messageText = "レイヤー「\(name)」を削除しますか?"
        var lines: [String] = []
        if locked { lines.append("このレイヤーはロックされています。") }
        if count > 0 { lines.append("中の \(count) 個のクリップもいっしょに消えます。") }
        lines.append("「編集 ▸ 取り消し」で元に戻せます。")
        a.informativeText = lines.joined(separator: "\n")
        a.alertStyle = .warning
        a.addButton(withTitle: "削除")
        a.addButton(withTitle: "キャンセル")
        return a.runModal() == .alertFirstButtonReturn
    }

    /// メニュー・右クリックからの削除。クリップがあるか、ロックされているときは確認する(ロックされていても確認のうえ消せる)。
    @discardableResult
    func requestDeleteLayer(_ index: Int) -> Bool {
        guard !isLocked, let info = LayerEditing.deletionImpact(in: project, index: index),
              LayerEditing.deleteBlockedReason(in: project, index: index) == nil else { return false }
        if info.clipCount > 0 || info.locked {
            guard Self.confirmLayerDelete(info.name, info.clipCount, info.locked) else { return false }
        }
        return deleteLayer(index)
    }

    /// 確認なしで消す(Undo は 1 回)。ロックの確認は呼ぶ側。選択は消えたクリップの分だけ外れ、レイヤーの選択は外す。
    @discardableResult
    func deleteLayer(_ index: Int) -> Bool {
        guard !isLocked, let p = LayerEditing.delete(in: project, index: index) else { return false }
        let ok = edit("レイヤーの削除", enforcesLock: false) { $0 = p }
        if ok {
            // 消えたクリップの選択を外す(残っているクリップの選択はそのまま)
            let alive = Set(project.allClips.map(\.id))
            selectedClipIDs = selectedClipIDs.filter { alive.contains($0) }
            if let id = selectedClipId, !alive.contains(id) { selectedClipId = nil }
            selectedLayerIndex = nil
        }
        return ok
    }
}
