import Foundation

// MARK: - 複合クリップの中を編集する(「中に入る」)
//
// 「中に入る」と、タイムラインには複合クリップの中のレイヤーが出る。モデルは次の 2 つを持つ:
// - 根(root): 書類そのもの(保存・書き出し・Undo の単位)。
// - 見え方(view): 根の `tracks` を、入っている複合クリップ(入れ子なら外側から順に並べた id の列 = path)の中身に差し替えたプロジェクト。
//   編集はすべて view に対して行い、`embed` で根に戻す。Undo は根の全体を覚えるので、中に入る前後・出た後でも 1 編集 = 1 回で戻る。
// ここは画面に依存しない純粋な計算。

public enum CompoundScope {
    /// path の先にある複合クリップの中身のレイヤー。見つからない・複合クリップでないなら nil。
    public static func innerTracks(of root: Project, path: [String]) -> [Track]? {
        var tracks = root.tracks
        for id in path {
            guard let c = tracks.lazy.flatMap({ $0.clips }).first(where: { $0.id == id && $0.type == .compound }) else { return nil }
            tracks = c.tracks ?? []
        }
        return tracks
    }

    /// 見え方: 根の `tracks` を中身へ差し替えたプロジェクト(他の設定は根のまま)。path が空なら根そのもの。
    public static func view(of root: Project, path: [String]) -> Project? {
        guard let inner = innerTracks(of: root, path: path) else { return nil }
        var v = root
        v.tracks = inner
        return v
    }

    /// 見え方を根へ戻す: view の `tracks` を path の先の複合クリップの中身にして、それ以外の設定は view のものを採る。
    /// 複合クリップが根に無ければ nil。path が空なら view そのもの。
    public static func embed(view: Project, into root: Project, path: [String]) -> Project? {
        guard !path.isEmpty else { return view }
        guard let tracks = replacing(root.tracks, path: path[...], with: view.tracks) else { return nil }
        var out = view
        out.tracks = tracks
        return out
    }

    private static func replacing(_ tracks: [Track], path: ArraySlice<String>, with inner: [Track]) -> [Track]? {
        guard let id = path.first else { return inner }
        var out = tracks
        for ti in out.indices {
            guard let ci = out[ti].clips.firstIndex(where: { $0.id == id && $0.type == .compound }) else { continue }
            guard let sub = replacing(out[ti].clips[ci].tracks ?? [], path: path.dropFirst(), with: inner) else { return nil }
            out[ti].clips[ci].tracks = sub
            return out
        }
        return nil
    }

    /// path のどこかの複合クリップ(またはそのクリップのあるレイヤー)がロックされているか。そうなら中の編集は断る。
    public static func ancestorLocked(_ root: Project, path: [String]) -> Bool {
        var tracks = root.tracks
        for id in path {
            var next: [Track]?
            for t in tracks {
                if let c = t.clips.first(where: { $0.id == id && $0.type == .compound }) {
                    if t.isLocked || c.isClipLocked { return true }
                    next = c.tracks ?? []
                    break
                }
            }
            guard let n = next else { return false }
            tracks = n
        }
        return false
    }

    /// パンくず用の表示名: 「プロジェクト」の後ろに、入っている複合クリップの名前(メモがあればそれ、無ければ「複合クリップ n」)を並べる。
    public static func breadcrumb(_ root: Project, path: [String], rootTitle: String = "プロジェクト") -> [String] {
        var names = [rootTitle]
        var tracks = root.tracks
        for (n, id) in path.enumerated() {
            guard let c = tracks.lazy.flatMap({ $0.clips }).first(where: { $0.id == id && $0.type == .compound }) else { break }
            let note = (c.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            names.append(note.isEmpty ? "複合クリップ \(n + 1)" : note)
            tracks = c.tracks ?? []
        }
        return names
    }
}
