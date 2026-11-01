import Foundation

/// 欠けている素材(画像・動画・音声・ボイスの元ファイル)の検出と、場所の再指定(C-2 の一部。画面に依存しない)。
public enum MissingMedia {
    public struct Item: Equatable {
        public var clipId: String
        public var trackName: String
        public var path: String
        public var fileName: String { (path as NSString).lastPathComponent }
    }

    /// `src` を持つクリップのうち、ファイルが無いもの(トラック順・クリップ順)。`src` が空のものは数えない。
    public static func find(in project: Project, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [Item] {
        var out: [Item] = []
        for tr in project.tracks {
            for c in tr.clips {
                guard let src = c.src, !src.isEmpty, !exists(src) else { continue }
                out.append(Item(clipId: c.id, trackName: tr.name, path: src))
            }
        }
        return out
    }

    /// 書き出しを止める文言(先頭の数件の名前を並べ、残りは件数で示す)。
    public static func blockMessage(_ items: [Item], limit: Int = 5) -> String {
        let names = items.prefix(limit).map { "・\($0.fileName)(レイヤー「\($0.trackName)」)" }
        var msg = "素材が見つからないため書き出せません。素材の場所を直してから、もう一度書き出してください。\n" + names.joined(separator: "\n")
        if items.count > limit { msg += "\nほか \(items.count - limit) 件" }
        return msg
    }

    /// 欠けた素材を、`index`(ファイル名 → 新しいパス)で探し直して差し替える。見つかった数と、まだ欠けている数を返す。
    /// 何も変わらなければ `project` はそのまま(`changed` が false)。
    public static func relink(_ project: Project, index: [String: String], exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) })
        -> (project: Project, relinked: Int, stillMissing: Int) {
        var p = project
        var relinked = 0
        var still = 0
        for ti in p.tracks.indices {
            for ci in p.tracks[ti].clips.indices {
                guard let src = p.tracks[ti].clips[ci].src, !src.isEmpty, !exists(src) else { continue }
                let name = (src as NSString).lastPathComponent
                if let new = index[name], new != src, exists(new) {
                    p.tracks[ti].clips[ci].src = new
                    relinked += 1
                } else {
                    still += 1
                }
            }
        }
        return (p, relinked, still)
    }
}
