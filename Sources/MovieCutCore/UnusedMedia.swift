import Foundation

/// 未使用の素材: 取り込んだ素材(`Project.mediaPool`)のうち、どのクリップ(複合クリップの中身も含む)からも使われていないもの。
/// 一覧から消しても、ディスクのファイルは消さない(画面に依存しない純粋なロジック)。
public enum UnusedMedia {
    public struct Item: Equatable {
        public var path: String
        public var fileName: String { (path as NSString).lastPathComponent }
        public var directory: String { (path as NSString).deletingLastPathComponent }
    }

    /// クリップが参照するファイルのパス(素材・エフェクトの LUT など)。複合クリップの中身も再帰的に集める。
    static func collect(_ clips: [Clip], into out: inout Set<String>) {
        for c in clips {
            if let s = c.src, !s.isEmpty { out.insert(s) }
            for e in c.effects { if let p = e.path, !p.isEmpty { out.insert(p) } }
            for tr in c.tracks ?? [] { collect(tr.clips, into: &out) }
        }
    }

    /// 使われているファイルのパス(クリップとキャラクターの画像)。
    public static func usedPaths(in p: Project) -> Set<String> {
        var out = Set<String>()
        for tr in p.tracks { collect(tr.clips, into: &out) }
        for ch in p.characters {
            for s in [ch.imgClosed, ch.imgOpen, ch.imgBlink] + Array((ch.imgVowels ?? [:]).values) { if let s, !s.isEmpty { out.insert(s) } }
            for s in (ch.expressions ?? [:]).values where !s.isEmpty { out.insert(s) }
            for s in ch.rig?.allPaths ?? [] where !s.isEmpty { out.insert(s) }
        }
        return out
    }

    /// 未使用の素材(取り込んだ順)。
    public static func find(in p: Project) -> [Item] {
        let used = usedPaths(in: p)
        return p.mediaPool.filter { !used.contains($0) }.map { Item(path: $0) }
    }

    /// 動画・音声・画像のクリップが参照するファイル(出てきた順、複合の中身も含む)。声(生成した音声のキャッシュ)は含めない。
    static func mediaSources(_ clips: [Clip]) -> [String] {
        var out: [String] = []
        for c in clips {
            if [ClipType.video, .audio, .image].contains(c.type), let s = c.src, !s.isEmpty, !out.contains(s) { out.append(s) }
            for tr in c.tracks ?? [] { for s in mediaSources(tr.clips) where !out.contains(s) { out.append(s) } }
        }
        return out
    }

    /// 編集で、どのクリップからも使われなくなった素材(動画・音声・画像)を素材リストに覚える。
    /// `mediaPool` ができる前の書類で消したクリップ、素材リストに入っていなかったクリップも、これ以降は「未使用の素材」に出る。
    /// (すでに消えたクリップの素材は、書類に記録が無いので取り戻せない。)何も使われなくならなければ何も変えない。
    public static func adoptRemoved(from old: Project, into new: inout Project) {
        let before = mediaSources(old.tracks.flatMap(\.clips))
        guard !before.isEmpty else { return }
        let after = Set(mediaSources(new.tracks.flatMap(\.clips)))
        let gone = before.filter { !after.contains($0) }
        guard !gone.isEmpty else { return }
        let used = usedPaths(in: new)
        register(gone.filter { !used.contains($0) }, in: &new)
    }

    /// 取り込んだ素材として覚える(重複は足さない)。
    public static func register(_ paths: [String], in p: inout Project) {
        for s in paths where !s.isEmpty && !p.mediaPool.contains(s) { p.mediaPool.append(s) }
    }

    /// 指定した素材を素材リストから外す(ディスクには触らない)。使われているものは外さない。
    public static func remove(_ paths: Set<String>, from p: inout Project) {
        let used = usedPaths(in: p)
        p.mediaPool.removeAll { paths.contains($0) && !used.contains($0) }
    }

    /// 未使用の素材をすべて外す。
    public static func removeAll(from p: inout Project) {
        let unused = Set(find(in: p).map(\.path))
        remove(unused, from: &p)
    }
}
