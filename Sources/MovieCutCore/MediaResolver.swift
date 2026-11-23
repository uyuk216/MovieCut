import Foundation

/// プロジェクトファイルの場所を基準にした素材パスの解決(Resolver)。
///
/// 解決順序:
///   1. そのまま存在するパス
///   2. プロジェクト相対で解決(src が相対パスならプロジェクトフォルダ基準、
///      絶対パスでも末尾の相対部分がプロジェクト配下にあればそこから解決)
///   3. それでも見つからなければ再リンク(`MediaRelinker`)の責務
///
/// 既存の `MediaPaths.contained`(「..」やシンボリックリンクでの外への脱出を防ぐ)を
/// 相対解決にそのまま使う。
public enum MediaResolver {
    /// src を実パスへ解決する。見つからなければ nil。
    public static func resolve(src: String, projectDir: String?,
                               exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String? {
        guard !src.isEmpty else { return nil }
        // 相対パスはプロジェクトフォルダ基準を先に試す(作業フォルダの同名ファイルに化けないように)
        if !src.hasPrefix("/") {
            if let projectDir, !projectDir.isEmpty,
               let p = MediaPaths.contained(relative: src, in: projectDir), exists(p) { return p }
            if exists(src) { return src }
            return nil
        }
        // 1. そのまま存在
        if exists(src) { return src }
        guard let projectDir, !projectDir.isEmpty else { return nil }
        // 2b. 絶対パス: プロジェクト配下だったものは、プロジェクトが移動しても
        //     「プロジェクトフォルダ名以降の相対部分」で新しい場所から解決できる。
        //     フォルダ名を含む末尾から順に短くしながら、存在するものを探す。
        if let p = resolveMovedAbsolute(src: src, projectDir: projectDir, exists: exists) { return p }
        return nil
    }

    /// 絶対パスの src が現在のプロジェクトフォルダ配下なら、相対パス表現を返す。
    /// 配下でなければ nil(相対として扱えない)。
    public static func relativePath(forAbsolute src: String, projectDir: String) -> String? {
        let base = (projectDir as NSString).standardizingPath
        let path = (src as NSString).standardizingPath
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    /// src が絶対/相対どちらの場合でも、プロジェクト基準の相対表現にできる場合はそれを返す。
    public static func relativize(src: String, projectDir: String) -> String? {
        if !src.hasPrefix("/") { return src }
        return relativePath(forAbsolute: src, projectDir: projectDir)
    }

    private static func resolveMovedAbsolute(src: String, projectDir: String,
                                             exists: (String) -> Bool) -> String? {
        // プロジェクトフォルダ名をアンカーにする: src のパス要素の中から
        // フォルダ名と一致する位置を探し、そこから後ろを相対として解決する。
        let folderName = (projectDir as NSString).lastPathComponent
        guard !folderName.isEmpty else { return nil }
        let comps = src.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        // 最後に現れるフォルダ名の位置を使う(同名フォルダが途中にあっても末尾側を優先)。
        guard let idx = comps.lastIndex(of: folderName), idx + 1 < comps.count else { return nil }
        let rel = comps[(idx + 1)...].joined(separator: "/")
        if let p = MediaPaths.contained(relative: rel, in: projectDir), exists(p) { return p }
        return nil
    }
}

/// リンク切れ素材の一括再リンク。
///
/// 候補フォルダ群を走査し、対応表(旧パス → 新パス)を返す。
/// 一致のルール:
///   - フィンガープリントがある素材は **ハッシュ一致のみ**でつなぐ(同名・同サイズでも、ハッシュが違う候補はもちろん、ハッシュを読めなかった候補も絶対につながない)
///   - フィンガープリントが無い素材だけ、目印(MediaHint)併用のファイル名 + サイズ一致でつなぐ(後方互換)
/// 見つからないものは `unresolved` に残す(プレースホルダ表示は既存 `MissingMedia` /
/// `MissingMediaPlaceholder` の責務で、ここでは素材を捏造しない)。
public enum MediaRelinker {
    public struct Result: Equatable {
        /// 旧パス → 新パス。
        public var mapping: [String: String] = [:]
        /// 見つからなかった旧パス(元の順序)。
        public var unresolved: [String] = []
        public init(mapping: [String: String] = [:], unresolved: [String] = []) {
            self.mapping = mapping; self.unresolved = unresolved
        }
    }

    private struct CandidateFile {
        var path: String
        var fileName: String
        var size: Int64?
    }

    /// 候補フォルダ群を再帰走査して候補ファイル一覧を作る(隠しファイルは除く、パス順)。
    private static func scan(candidateFolders: [URL], fileManager: FileManager = .default) -> [CandidateFile] {
        var out: [CandidateFile] = []
        for root in candidateFolders {
            guard let e = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                                 options: [.skipsHiddenFiles]) else { continue }
            for case let u as URL in e {
                guard let v = try? u.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                      v.isRegularFile == true else { continue }
                out.append(CandidateFile(path: u.path, fileName: u.lastPathComponent,
                                         size: v.fileSize.map { Int64($0) }))
            }
        }
        return out.sorted { $0.path < $1.path }
    }

    /// 素材参照ごとの一括再リンク(純粋に近い形: 実ファイル走査とハッシュ計算のみ外部依存)。
    public static func relink(missing sources: [String],
                              fingerprints: [String: MediaFingerprint],
                              hints: [String: MediaHint] = [:],
                              candidateFolders: [URL],
                              compute: (String) -> MediaFingerprint? = { MediaFingerprint.compute(atPath: $0) }) -> Result {
        let candidates = scan(candidateFolders: candidateFolders)
        var result = Result()
        for src in sources {
            if let found = findReplacement(for: src, fingerprint: fingerprints[src], hint: hints[src],
                                           candidates: candidates, compute: compute) {
                result.mapping[src] = found
            } else {
                result.unresolved.append(src)
            }
        }
        return result
    }

    /// プロジェクト単位: 欠け素材を検出し、再リンクの対応表を返す。プロジェクト自体は変更しない。
    public static func relinkProject(_ project: Project, projectDir: String? = nil,
                                     candidateFolders: [URL]) -> Result {
        let missing = MissingMedia.find(in: project, exists: {
            MediaResolver.resolve(src: $0, projectDir: projectDir) != nil
        }).map(\.path)
        // MissingMedia.find は同じ src の重複をクリップごとに返すので distinct にする
        var seen = Set<String>(); let distinct = missing.filter { seen.insert($0).inserted }
        return relink(missing: distinct, fingerprints: project.mediaFingerprints,
                      hints: project.mediaHints, candidateFolders: candidateFolders)
    }

    /// 対応表をプロジェクトへ適用したコピーを返す(src と mediaPool を差し替える)。
    public static func applying(_ mapping: [String: String], to project: Project) -> Project {
        guard !mapping.isEmpty else { return project }
        var p = project
        // 複合の内側・シーン定義の中の参照も差し替える(検出だけ入れ子対応で、適用が最上位だけだと直らない)
        func walk(_ tracks: inout [Track]) {
            for ti in tracks.indices {
                for ci in tracks[ti].clips.indices {
                    if let src = tracks[ti].clips[ci].src, let new = mapping[src] {
                        tracks[ti].clips[ci].src = new
                    }
                    if tracks[ti].clips[ci].tracks != nil {
                        var inner = tracks[ti].clips[ci].tracks!
                        walk(&inner)
                        tracks[ti].clips[ci].tracks = inner
                    }
                }
            }
        }
        walk(&p.tracks)
        for si in p.scenes.indices { walk(&p.scenes[si].tracks) }
        p.mediaPool = p.mediaPool.map { mapping[$0] ?? $0 }
        // フィンガープリント・ヒントのキーも新しいパスへ移す(旧パスのままだと次の再リンクで照合できない)
        var fps: [String: MediaFingerprint] = [:]
        for (k, v) in p.mediaFingerprints { fps[mapping[k] ?? k] = v }
        p.mediaFingerprints = fps
        var hs: [String: MediaHint] = [:]
        for (k, v) in p.mediaHints { hs[mapping[k] ?? k] = v }
        p.mediaHints = hs
        return p
    }

    private static func findReplacement(for src: String, fingerprint: MediaFingerprint?,
                                        hint: MediaHint?, candidates: [CandidateFile],
                                        compute: (String) -> MediaFingerprint?) -> String? {
        // 1. ハッシュ一致を最優先(サイズが同じ候補だけハッシュを読む)
        if let fp = fingerprint {
            let sameSize = candidates.filter { $0.size == fp.size }
            for c in sameSize {
                if let got = compute(c.path), got.sha256 == fp.sha256, got.size == fp.size {
                    return c.path
                }
            }
            // フィンガープリントがある素材はここで確定: ハッシュで一致を
            // 確認できなかった候補(違う・読めない)は、同名・同サイズでも
            // 絶対につながない(仕様01 R-03、安全側)。
            return nil
        }
        // フィンガープリントが無い場合は、目印(MediaHint)のサイズを使ってファイル名+サイズで探す。
        // サイズの目印も無い場合はファイル名のみ(既存 MissingMedia.relink と同じ後方互換の振る舞い)。
        let name = (src as NSString).lastPathComponent
        for c in candidates where c.fileName == name {
            if let want = hint?.size {
                if c.size == want { return c.path } else { continue }
            }
            return c.path
        }
        return nil
    }
}
