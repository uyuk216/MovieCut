import Foundation
import MovieCutCore

/// 素材メタデータとスマートコレクションの編集(ロジックは Core の `MediaMetadataEditing`)。
/// どの操作も `edit` を 1 回だけ通るので、Undo は 1 回で戻る。変わらない操作は履歴に載らない。
extension ProjectModel {
    /// 素材のメタデータ(無ければ nil)。`src` は素材の参照文字列(素材ブラウザではファイルのパス)。
    func mediaMetadata(for src: String) -> MediaMetadata? {
        MediaMetadataEditing.metadata(for: src, in: project)
    }

    /// 素材のメタデータを丸ごと差し替える(Undo 1 回)。空を渡すと消去と同じ。
    @discardableResult
    func setMediaMetadata(_ metadata: MediaMetadata, for src: String) -> Bool {
        guard !isLocked else { return false }
        let ok = edit("素材のメタデータの変更") { p in
            MediaMetadataEditing.set(metadata, for: src, in: &p)
        }
        if ok { statusText = "素材のメタデータを変更しました" }
        return ok
    }

    /// キーワード・評価・メモ・ラベルをまとめて差し替える(Undo 1 回)。
    /// 素材ブラウザの編集欄はこの 1 本で保存する(欄ごとに Undo が分かれない)。
    @discardableResult
    func updateMediaMetadata(for src: String, keywords: [String], rating: Int?, note: String?, label: String?) -> Bool {
        setMediaMetadata(MediaMetadata(keywords: keywords, rating: rating, note: note, label: label), for: src)
    }

    /// 素材のメタデータをすべて消す(Undo 1 回)。
    @discardableResult
    func clearMediaMetadata(for src: String) -> Bool {
        guard !isLocked else { return false }
        return edit("素材のメタデータの消去") { p in
            MediaMetadataEditing.clear(for: src, in: &p)
        }
    }

    /// プロジェクト内で使われているキーワードすべて(候補表示用)。
    var allMediaKeywords: [String] { MediaMetadataEditing.allKeywords(in: project) }

    /// 条件に合う素材の参照文字列の一覧(素材ブラウザの絞り込みと同じ条件の意味)。
    func mediaSources(matching criteria: MediaFilterCriteria) -> [String] {
        MediaMetadataEditing.filteredSources(in: project, criteria: criteria)
    }

    /// スマートコレクションに合う素材の参照文字列の一覧。
    func mediaSources(in collection: SmartCollection) -> [String] {
        MediaMetadataEditing.sources(in: project, matching: collection)
    }

    /// スマートコレクションを足す(Undo 1 回)。足したコレクションを返す(足せなかったときは nil)。
    @discardableResult
    func addSmartCollection(name: String, criteria: MediaFilterCriteria) -> SmartCollection? {
        guard !isLocked else { return nil }
        var made: SmartCollection?
        let ok = edit("スマートコレクションの追加") { p in
            made = MediaMetadataEditing.addCollection(name: name, criteria: criteria, in: &p)
        }
        if ok { statusText = "スマートコレクション「\(name)」を追加しました" }
        return ok ? made : nil
    }

    /// スマートコレクションを差し替える(Undo 1 回)。
    @discardableResult
    func updateSmartCollection(_ collection: SmartCollection) -> Bool {
        guard !isLocked else { return false }
        return edit("スマートコレクションの変更") { p in
            MediaMetadataEditing.updateCollection(collection, in: &p)
        }
    }

    /// スマートコレクションを消す(Undo 1 回)。素材そのものは消えない(条件だけが消える)。
    @discardableResult
    func removeSmartCollection(id: String) -> Bool {
        guard !isLocked else { return false }
        let ok = edit("スマートコレクションの削除") { p in
            MediaMetadataEditing.removeCollection(id: id, in: &p)
        }
        if ok { statusText = "スマートコレクションを削除しました(素材は消えません)" }
        return ok
    }
}
