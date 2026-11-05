import Foundation

/// 欠けている素材(画像・動画・音声・ボイスの元ファイル)の検出と、場所の再指定(画面に依存しない)。
public enum MissingMedia {
    public struct Item: Equatable {
        public var clipId: String
        public var trackName: String
        public var path: String
        public var fileName: String { (path as NSString).lastPathComponent }
    }

    /// 探し直しの候補(フォルダの中の 1 ファイル)。サイズは読めたときだけ入る。
    public struct Candidate: Equatable {
        public var path: String
        public var size: Int64?
        public init(path: String, size: Int64? = nil) { self.path = path; self.size = size }
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

    /// フォルダを再帰的に調べ、ファイル名 → 候補(パスとサイズ)の表を作る。隠しファイルは除く。候補はパス順。
    public static func index(root: URL, fileManager: FileManager = .default) -> [String: [Candidate]] {
        var out: [String: [Candidate]] = [:]
        guard let e = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                             options: [.skipsHiddenFiles]) else { return out }
        for case let u as URL in e {
            guard let v = try? u.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), v.isRegularFile == true else { continue }
            let size = v.fileSize.map { Int64($0) }
            out[u.lastPathComponent, default: []].append(Candidate(path: u.path, size: size))
        }
        for k in out.keys { out[k]?.sort { $0.path < $1.path } }
        return out
    }

    /// 欠けた素材を探し直して差し替える。順に試す: (1) 目印の相対パス(`projectDir` 基準)、(2) 同じファイル名の候補。
    /// (2) は目印にサイズがあれば、サイズも一致するものだけ使う(同名の別ファイルを誤って選ばない)。
    /// 見つかった数と、まだ欠けている数を返す。何も変わらなければ `project` はそのまま。
    public static func relink(_ project: Project, candidates: [String: [Candidate]], projectDir: String? = nil,
                              exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) })
        -> (project: Project, relinked: Int, stillMissing: Int) {
        var p = project
        var relinked = 0
        var still = 0
        for ti in p.tracks.indices {
            for ci in p.tracks[ti].clips.indices {
                guard let src = p.tracks[ti].clips[ci].src, !src.isEmpty, !exists(src) else { continue }
                if let new = findReplacement(for: src, hint: project.mediaHints[src], candidates: candidates,
                                             projectDir: projectDir, exists: exists) {
                    p.tracks[ti].clips[ci].src = new
                    relinked += 1
                } else {
                    still += 1
                }
            }
        }
        return (p, relinked, still)
    }

    /// 後方互換: ファイル名 → 1 つのパスの表で探し直す(サイズは見ない)。
    public static func relink(_ project: Project, index: [String: String], exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) })
        -> (project: Project, relinked: Int, stillMissing: Int) {
        relink(project, candidates: index.mapValues { [Candidate(path: $0)] }, exists: exists)
    }

    /// 1 件分の探し直し先。見つからなければ nil。
    static func findReplacement(for src: String, hint: MediaHint?, candidates: [String: [Candidate]],
                                projectDir: String?, exists: (String) -> Bool) -> String? {
        // パッケージの中の参照(相対の src)は、プロジェクトのフォルダ基準で読む
        if !src.hasPrefix("/"), let dir = projectDir, let p = MediaPaths.contained(relative: src, in: dir) {
            if exists(p) { return p }
        }
        if let rel = hint?.relative, let dir = projectDir, !rel.isEmpty, let p = MediaPaths.contained(relative: rel, in: dir) {
            if p != src, exists(p) { return p }
        }
        let name = (src as NSString).lastPathComponent
        for c in candidates[name] ?? [] where c.path != src && exists(c.path) {
            if let want = hint?.size, let got = c.size, want != got { continue }
            if hint?.size != nil, c.size == nil { continue }
            return c.path
        }
        return nil
    }
}

/// プロジェクトのフォルダを基準にした相対パスの安全な解決。
public enum MediaPaths {
    /// `relative` を `dir` の下に置いたパス。絶対パス・「..」・NUL を含むもの、結果が `dir` の外(シンボリックリンクで抜ける場合を含む)になるものは nil。
    public static func contained(relative: String, in dir: String) -> String? {
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.contains("\0") else { return nil }
        let comps = relative.split(separator: "/", omittingEmptySubsequences: true)
        guard !comps.isEmpty, !comps.contains("..") else { return nil }
        let base = URL(fileURLWithPath: dir, isDirectory: true)
        let joined = comps.reduce(base) { $0.appendingPathComponent(String($1)) }
        let realBase = base.resolvingSymlinksInPath().standardizedFileURL.path
        // まだ無いファイルでも、存在する一番深い親をシンボリックリンクごと解決して調べる
        var existing = joined, rest: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            rest.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        let realJoined = rest.reduce(existing.resolvingSymlinksInPath().standardizedFileURL) { $0.appendingPathComponent($1) }.path
        guard realJoined == realBase || realJoined.hasPrefix(realBase.hasSuffix("/") ? realBase : realBase + "/") else { return nil }
        return (dir as NSString).appendingPathComponent(relative)
    }
}
