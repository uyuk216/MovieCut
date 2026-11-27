import Foundation

// 生成プロキシをプロジェクト内の資産として扱う(仕様01 M-06/M-07)。画面に依存しない純粋なロジック。
// 置き場: プロジェクトファイルの隣の `proxies/`(パッケージ保存でもパッケージ直下の `proxies/`)。
// 記録: `Project.proxyAssets`(元の素材のパス → フォルダからの相対パス)。フォルダごと移動・共有しても相対で引ける。
// 従来のアプリ側ディレクトリ(`ProxyStore.defaultDirectory()`)の生成プロキシは、記録が無ければ従来のキーで引く(後方互換)。
// 書き出しは常に原本(ここは関与しない)。

public enum ProxyLocation: Equatable, Sendable { case project, app }

public struct GeneratedProxy: Equatable, Sendable {
    public var url: URL
    public var location: ProxyLocation
}

public enum ProxyAssets {
    public static let folderName = "proxies"

    /// プロジェクトファイルのフォルダ内の置き場。
    public static func directory(projectDir: URL) -> URL {
        projectDir.appendingPathComponent(folderName, isDirectory: true)
    }

    private static func fileSize(_ path: String) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.size].flatMap { ($0 as? NSNumber)?.int64Value }
    }

    /// 記録の相対パスを実パスにする(「..」での外への脱出は無効)。
    private static func resolve(_ asset: ProxyAsset, projectDir: URL) -> URL? {
        guard let p = MediaPaths.contained(relative: asset.file, in: projectDir.path) else { return nil }
        return URL(fileURLWithPath: p)
    }

    /// 生成したプロキシを記録したコピーを返す。`proxy` がプロジェクトフォルダの外なら記録しない(nil)。
    public static func recording(_ p: Project, source: String, proxy: URL, projectDir: URL) -> Project? {
        guard let rel = MediaResolver.relativePath(forAbsolute: proxy.standardizedFileURL.path,
                                                  projectDir: projectDir.standardizedFileURL.path) else { return nil }
        var q = p
        q.proxyAssets[source] = ProxyAsset(file: rel, sourceSize: fileSize(source))
        return q
    }

    /// 素材の生成済みプロキシ。プロジェクトの記録(実在・原本の大きさが合う)を優先し、無ければ従来のアプリ側(キー)。
    public static func locate(source: String, in p: Project, projectDir: URL?, legacyDirectory: URL) -> GeneratedProxy? {
        if let projectDir, let asset = p.proxyAssets[source], let u = resolve(asset, projectDir: projectDir),
           FileManager.default.fileExists(atPath: u.path) {
            let original = MediaResolver.resolve(src: source, projectDir: projectDir.path) ?? source
            let stale: Bool = {
                guard let want = asset.sourceSize, let now = fileSize(original) else { return false }   // 原本が手元に無ければ記録を信じる
                return want != now
            }()
            if !stale { return GeneratedProxy(url: u, location: .project) }
        }
        if let u = ProxyStore.existingProxy(for: URL(fileURLWithPath: source), directory: legacyDirectory) {
            return GeneratedProxy(url: u, location: .app)
        }
        return nil
    }

    /// 管理画面用: プロジェクトが記録している生成プロキシの一覧(ファイルが実在するものだけ。素材のパス昇順)。
    public static func listProject(_ p: Project, projectDir: URL) -> [(source: String, url: URL, bytes: Int64)] {
        p.proxyAssets.keys.sorted().compactMap { src in
            guard let a = p.proxyAssets[src], let u = resolve(a, projectDir: projectDir),
                  FileManager.default.fileExists(atPath: u.path) else { return nil }
            return (src, u, fileSize(u.path) ?? 0)
        }
    }

    /// 素材のプロジェクト内プロキシを消して記録を外す。素材・外部プロキシ・アプリ側(従来)のファイルには触らない。
    public static func removeProject(source: String, from p: Project, projectDir: URL) -> (project: Project, removed: Bool) {
        guard let a = p.proxyAssets[source] else { return (p, false) }
        var removed = false
        if let u = resolve(a, projectDir: projectDir), FileManager.default.fileExists(atPath: u.path) {
            removed = (try? FileManager.default.removeItem(at: u)) != nil
            if !removed { return (p, false) }   // 消せなかったら記録も残す
        }
        var q = p
        q.proxyAssets[source] = nil
        return (q, removed)
    }

    /// アプリ側(従来・暫定置き場)の生成プロキシを、プロジェクトフォルダへ「コピー」して記録する。元のアプリ側ファイルは消さない(後方互換・他の書類が使っているかもしれない)。
    /// 既にプロジェクト側に記録がある素材は飛ばす。戻り値は記録したコピーと取り込んだ件数。
    public static func adoptLegacy(_ p: Project, sources: [String], projectDir: URL, legacyDirectory: URL) -> (project: Project, adopted: Int) {
        var q = p
        var n = 0
        let fm = FileManager.default
        for src in sources {
            if locate(source: src, in: q, projectDir: projectDir, legacyDirectory: legacyDirectory)?.location == .project { continue }
            guard let legacy = ProxyStore.existingProxy(for: URL(fileURLWithPath: src), directory: legacyDirectory) else { continue }
            let dest = directory(projectDir: projectDir).appendingPathComponent(legacy.lastPathComponent)
            do {
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !fm.fileExists(atPath: dest.path) { try fm.copyItem(at: legacy, to: dest) }
            } catch { continue }
            if let r = recording(q, source: src, proxy: dest, projectDir: projectDir) { q = r; n += 1 }
        }
        return (q, n)
    }
}
