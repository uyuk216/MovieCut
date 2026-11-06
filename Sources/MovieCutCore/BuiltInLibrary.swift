import Foundation

// MARK: - 同梱素材ライブラリ(素材ブラウザの「Movie Cut 同梱」)
//
// 効果音 12・背景 6・図形 6 を、このアプリが自分で合成・描画して `DataLocations.builtinMedia` に書く(初回だけ。以後はキャッシュ)。
// 第三者の素材は使わない。ライセンス: このアプリが生成したものでライセンス自由(`docs/同梱素材のライセンス.md`、フォルダの中にも同じ文を置く)。
// 一覧は普通のフォルダと同じ(`MediaBrowser.scan`)なので、ダブルクリックでの配置・ドラッグ・試し聴きも他の素材と同じ。

public enum BuiltInLibrary {
    /// 素材ブラウザの見出し。
    public static let title = "Movie Cut 同梱"
    public static let licenseNote = "このアプリが生成したものでライセンス自由"
    public static let licenseFileName = "ライセンス.txt"
    /// 合成の式を変えたら上げる(古いキャッシュを書き直す)。印のファイルに入れる。
    public static let version = 1
    static let versionFileName = ".version"

    /// 期待するファイル名の一覧(効果音 12・背景 6・図形 6)。
    public static var fileNames: [String] {
        BuiltInSounds.specs.map { $0.title + ".wav" } + BuiltInImages.specs.map { $0.title + ".png" }
    }

    /// 同梱素材のフォルダ(作らない)。
    public static func folder(in locations: DataLocations = .current) -> URL { locations.builtinMedia }

    /// 足りないファイルを書いて、フォルダを返す(合成・描画は決まった式なので何度やっても同じ中身)。
    /// 版が違うときは全部書き直す。書けなかったファイルは飛ばす(返り値のフォルダには書けたものだけ)。
    @discardableResult
    public static func ensureInstalled(in locations: DataLocations = .current, fileManager fm: FileManager = .default) -> URL {
        let dir = folder(in: locations)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let versionURL = dir.appendingPathComponent(versionFileName)
        let current = (try? String(contentsOf: versionURL, encoding: .utf8)).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let stale = current != version
        func write(_ data: Data?, _ name: String) {
            let url = dir.appendingPathComponent(name)
            if !stale, let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 0 { return }
            guard let data else { return }
            try? data.write(to: url, options: .atomic)
        }
        for s in BuiltInSounds.specs { if stale || !fm.fileExists(atPath: dir.appendingPathComponent(s.title + ".wav").path) { write(BuiltInSounds.wavData(BuiltInSounds.render(s.id)), s.title + ".wav") } }
        for s in BuiltInImages.specs { if stale || !fm.fileExists(atPath: dir.appendingPathComponent(s.title + ".png").path) { write(BuiltInImages.render(s.id).flatMap(BuiltInImages.pngData), s.title + ".png") } }
        try? (licenseNote + "\n").data(using: .utf8)?.write(to: dir.appendingPathComponent(licenseFileName), options: .atomic)
        try? "\(version)\n".data(using: .utf8)?.write(to: versionURL, options: .atomic)
        return dir
    }

    /// 素材ブラウザに出す一覧(必要なら先に書く)。
    public static func items(in locations: DataLocations = .current) -> [MediaBrowser.Item] {
        MediaBrowser.scan(folder: ensureInstalled(in: locations))
    }

    /// そのフォルダが同梱素材のフォルダか。
    public static func isBuiltIn(_ url: URL?, in locations: DataLocations = .current) -> Bool {
        guard let url else { return false }
        return url.standardizedFileURL.path == folder(in: locations).standardizedFileURL.path
    }
}
