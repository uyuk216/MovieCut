import AppKit
import UniformTypeIdentifiers
import MovieCutCore

/// レビューコメント(移動 ▸ レビューコメント)。追加・編集・解決済みの切り替え・位置への移動と、
/// 交換用 JSON の書き出し/読み込み。すべて通常の編集と同じく Undo 1 回で戻せる。
/// 外部サービスへの送信はしない(ファイルの受け渡しのみ)。
extension ProjectModel {
    /// 作成者名の前回値(端末内にだけ残す。プロジェクトには書かない)。
    var reviewCommentAuthor: String {
        get { UserDefaults.standard.string(forKey: "reviewCommentAuthor") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "reviewCommentAuthor") }
    }

    static func isoNow() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date())
    }

    /// 再生位置にコメントを足す(対象クリップは選択中のクリップがあればその id)。本文が空なら足さない。
    @discardableResult
    func addReviewCommentAtPlayhead(body: String, author: String) -> String? {
        guard !isLocked else { return nil }
        let clipId = selectedClipId.flatMap { id in project.allClips.first { $0.id == id } != nil ? id : nil }
        guard let r = ReviewCommentEditing.add(in: project, at: currentTime, body: body, author: author,
                                                clipId: clipId, createdAt: Self.isoNow()) else { return nil }
        edit("レビューコメントの追加") { $0 = r.project }
        reviewCommentAuthor = author
        return r.id
    }

    /// 本文の編集(シートの行から)。
    @discardableResult
    func updateReviewCommentBody(id: String, to body: String) -> Bool {
        guard !isLocked, let p = ReviewCommentEditing.updateBody(in: project, id: id, to: body, updatedAt: Self.isoNow()) else { return false }
        edit("レビューコメントの編集") { $0 = p }
        return true
    }

    /// 解決済み/未解決の切り替え。
    @discardableResult
    func toggleReviewCommentResolved(id: String) -> Bool {
        guard !isLocked, let c = project.reviewComments.first(where: { $0.id == id }),
              let p = ReviewCommentEditing.setResolved(in: project, id: id, to: !c.resolved, updatedAt: Self.isoNow()) else { return false }
        edit(c.resolved ? "レビューコメントを未解決に戻す" : "レビューコメントを解決済みにする") { $0 = p }
        return true
    }

    @discardableResult
    func deleteReviewComment(id: String) -> Bool {
        guard !isLocked, let p = ReviewCommentEditing.remove(in: project, id: id) else { return false }
        edit("レビューコメントの削除") { $0 = p }
        return true
    }

    /// コメントの位置へ移動。
    @discardableResult
    func jumpToReviewComment(id: String) -> Bool {
        guard let c = project.reviewComments.first(where: { $0.id == id }) else { return false }
        playback.seek(to: c.time)
        return true
    }

    /// 交換用 JSON データ(シート・テスト用)。
    func reviewCommentsJSONData() -> Data? {
        try? ReviewCommentExchange.encodeJSON(project.reviewComments, exportedAt: Self.isoNow())
    }

    /// 交換ファイルの読み込みを 1 回の Undo で反映する。競合規則は ReviewCommentExchange.merge を参照。
    @discardableResult
    func importReviewComments(data: Data) -> ReviewCommentExchange.MergeResult? {
        guard !isLocked else { return nil }
        guard let incoming = try? ReviewCommentExchange.decodeJSON(data) else {
            errorTitle = "レビューコメントを読み込めませんでした"
            errorMessage = "レビューコメントの交換ファイル(JSON)として読み取れませんでした"
            return nil
        }
        let r = ReviewCommentExchange.merge(into: project, incoming: incoming)
        if r.added + r.updated > 0 {
            edit("レビューコメントの読み込み") { $0 = r.project }
        }
        statusText = "レビューコメントを読み込みました(追加 \(r.added) 件・更新 \(r.updated) 件・変更なし \(r.unchanged) 件)"
        return r
    }

    // MARK: パネル経由の書き出し/読み込み

    func chooseAndExportReviewComments() {
        guard !project.reviewComments.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.json, UTType.commaSeparatedText].compactMap { $0 }
        panel.nameFieldStringValue = "review-comments.json"
        panel.title = "レビューコメントを書き出す"
        let run: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            guard resp == .OK, let url = panel.url, let self else { return }
            do {
                if url.pathExtension.lowercased() == "csv" {
                    try ReviewCommentExchange.csv(self.project.reviewComments).write(to: url, atomically: true, encoding: .utf8)
                } else if let data = self.reviewCommentsJSONData() {
                    try data.write(to: url)
                }
                self.statusText = "レビューコメントを書き出しました(\(self.project.reviewComments.count) 件)"
            } catch {
                self.errorTitle = "レビューコメントを書き出せませんでした"
                self.errorMessage = error.localizedDescription
            }
        }
        if let w = window { panel.beginSheetModal(for: w, completionHandler: run) } else { panel.begin(completionHandler: run) }
    }

    func chooseAndImportReviewComments() {
        guard !isLocked else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if let t = UTType(filenameExtension: "json") { panel.allowedContentTypes = [t] }
        panel.title = "レビューコメントを読み込む"
        let run: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            guard resp == .OK, let url = panel.url, let self else { return }
            guard let data = try? Data(contentsOf: url) else {
                self.errorTitle = "レビューコメントを読み込めませんでした"
                self.errorMessage = "\(url.lastPathComponent): ファイルを読めませんでした"
                return
            }
            _ = self.importReviewComments(data: data)
        }
        if let w = window { panel.beginSheetModal(for: w, completionHandler: run) } else { panel.begin(completionHandler: run) }
    }
}
