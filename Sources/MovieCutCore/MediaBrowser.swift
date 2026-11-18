import Foundation
import AVFoundation
import ImageIO

// MARK: - 素材ブラウザの一覧(種類・検索・並べ替え・フォルダの走査・長さと読めるかの確認)

/// 素材ブラウザの純粋ロジック。画面は持たない。
/// 対象の拡張子は `ClipEditing` の一覧と同じ(ここで一覧に出たものは「タイムラインに追加」できる)。
/// 隠しファイル・通常のファイルでないものは飛ばす。サブフォルダは `subfolders(of:)`
/// で辿れるほか、`scan(folder:recursive:)` でまとめて走査できる(X-2)。
public enum MediaBrowser {
    /// 種類の絞り込み。
    public enum KindFilter: String, CaseIterable, Equatable, Sendable {
        case all, video, audio, image

        public var title: String {
            switch self {
            case .all: return "すべて"
            case .video: return "動画"
            case .audio: return "音声"
            case .image: return "画像"
            }
        }

        public func matches(_ kind: ClipType) -> Bool {
            switch self {
            case .all: return true
            case .video: return kind == .video
            case .audio: return kind == .audio
            case .image: return kind == .image
            }
        }
    }

    /// 並べ方。名前は自然順(昇順)、更新日は新しいものから、種類は 動画・音声・画像 の順に名前順。
    public enum SortKey: String, CaseIterable, Equatable, Sendable {
        case name, modified, kind

        public var title: String {
            switch self {
            case .name: return "名前"
            case .modified: return "更新日"
            case .kind: return "種類"
            }
        }
    }

    /// 一覧の 1 行(ファイル 1 つ)。`modified` は読めたときだけ。`duration` と `unreadable` は `probe` で埋める(走査直後は未確認)。
    public struct Item: Equatable, Identifiable, Sendable {
        public let url: URL
        public let name: String
        public let kind: ClipType
        public let modified: Date?
        /// 長さ(秒)。未確認・画像・読めないものは nil。
        public var duration: Double?
        /// 開けない・中身がない(壊れている・対応していない形式)。
        public var unreadable: Bool
        /// 走査の起点フォルダからの相対パス(サブフォルダ内は "sub/bgm.wav" の形。直下はファイル名そのまま)。
        public let relativePath: String
        public var id: String { url.path }

        public init(url: URL, name: String, kind: ClipType, modified: Date? = nil, duration: Double? = nil, unreadable: Bool = false, relativePath: String? = nil) {
            self.url = url
            self.name = name
            self.kind = kind
            self.modified = modified
            self.duration = duration
            self.unreadable = unreadable
            self.relativePath = relativePath ?? name
        }

        /// 所属フォルダの相対パス(直下のファイルは "")。
        public var directoryPath: String {
            (relativePath as NSString).deletingLastPathComponent
        }
    }

    /// サブフォルダ 1 つ(素材ブラウザの階層移動用)。
    public struct FolderInfo: Equatable, Identifiable, Sendable {
        public let url: URL
        public let name: String
        /// 起点フォルダからの相対パス(直下のフォルダはフォルダ名そのまま)。
        public let relativePath: String
        public var id: String { url.path }

        public init(url: URL, name: String, relativePath: String) {
            self.url = url
            self.name = name
            self.relativePath = relativePath
        }
    }

    /// ファイル名から種類を決める(大文字小文字は問わない)。対象外・隠しファイルは nil。
    public static func kind(forName name: String) -> ClipType? {
        guard !name.hasPrefix(".") else { return nil }
        let ext = (name as NSString).pathExtension.lowercased()
        if ClipEditing.videoExtensions.contains(ext) { return .video }
        if ClipEditing.audioExtensions.contains(ext) { return .audio }
        if ClipEditing.imageExtensions.contains(ext) { return .image }
        return nil
    }

    /// 名前の順(自然順: track2 は track10 より前)。同じ名前は path で安定させる。
    public static func sorted(_ items: [Item]) -> [Item] {
        sorted(items, by: .name)
    }

    /// 並べ方を指定して並べる。どの並べ方でも、同じ値のものは名前の順・path の順で安定させる。
    public static func sorted(_ items: [Item], by key: SortKey) -> [Item] {
        items.sorted { a, b in
            switch key {
            case .name:
                break
            case .modified:
                // 新しいものが先。日付が無いものは後ろ
                switch (a.modified, b.modified) {
                case let (x?, y?) where x != y: return x > y
                case (nil, .some): return false
                case (.some, nil): return true
                default: break
                }
            case .kind:
                let ra = kindRank(a.kind), rb = kindRank(b.kind)
                if ra != rb { return ra < rb }
            }
            let c = a.name.localizedStandardCompare(b.name)
            if c != .orderedSame { return c == .orderedAscending }
            return a.url.path < b.url.path
        }
    }

    private static func kindRank(_ k: ClipType) -> Int {
        switch k {
        case .video: return 0
        case .audio: return 1
        default: return 2
        }
    }

    /// 種類で絞り、検索語を名前に含むものだけを残して、並べる(既定は名前の自然順)。
    /// 検索は大文字小文字・全角半角・濁点の違いを無視する。空白だけの検索語は「全部」と同じ。
    public static func filter(_ items: [Item], kind: KindFilter, query: String, sort: SortKey = .name) -> [Item] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let hits = items.filter { item in
            guard kind.matches(item.kind) else { return false }
            if q.isEmpty { return true }
            let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
            return item.name.range(of: q, options: opts) != nil
                || item.relativePath.range(of: q, options: opts) != nil
        }
        return sorted(hits, by: sort)
    }

    /// フォルダの対象ファイルを一覧にする(同期・長さは測らない。更新日は読む)。フォルダが無い・読めないときは空。
    /// 既定は直下だけ(従来どおり)。`recursive` のときはサブフォルダも辿り(`maxDepth` は起点直下を 0 とした深さ)、
    /// 各ファイルの `relativePath` に起点からの相対パスが入る。
    public static func scan(folder: URL, recursive: Bool = false, maxDepth: Int = 8) -> [Item] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        if !recursive {
            guard let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
                return []
            }
            var out: [Item] = []
            for u in urls {
                guard let k = kind(forName: u.lastPathComponent) else { continue }
                let values = try? u.resourceValues(forKeys: Set(keys))
                // 通常のファイルでないもの(フォルダ・壊れたリンク)は除く
                guard values?.isRegularFile == true else { continue }
                out.append(Item(url: u, name: u.lastPathComponent, kind: k, modified: values?.contentModificationDate))
            }
            return sorted(out)
        }
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return []
        }
        var out: [Item] = []
        for case let u as URL in enumerator {
            let rel = relativePath(of: u, under: folder)
            // 深さ = 相対パスの区切り数(直下のファイルは 0)
            guard rel.components(separatedBy: "/").count - 1 <= maxDepth else {
                if (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            guard let k = kind(forName: u.lastPathComponent) else { continue }
            let values = try? u.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            out.append(Item(url: u, name: u.lastPathComponent, kind: k, modified: values?.contentModificationDate, relativePath: rel))
        }
        return sorted(out)
    }

    /// サブフォルダも含めて走査する(`scan(folder:recursive:)` の短い名前)。
    public static func scanTree(folder: URL, maxDepth: Int = 8) -> [Item] {
        scan(folder: folder, recursive: true, maxDepth: maxDepth)
    }

    /// `root` からの相対パス("/" 区切り)。範囲外のときはファイル名。
    static func relativePath(of url: URL, under root: URL) -> String {
        let base = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(base + "/") else { return url.lastPathComponent }
        return String(path.dropFirst(base.count + 1))
    }

    /// フォルダ直下のサブフォルダ一覧(名前の自然順)。パッケージ(.app など)・隠しフォルダは除く。
    /// `root` を渡すと `relativePath` が起点からの相対パスになる(省略時は `folder` の直下として名前そのまま)。
    public static func subfolders(of folder: URL, root: URL? = nil) -> [FolderInfo] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return []
        }
        var out: [FolderInfo] = []
        for u in urls {
            let values = try? u.resourceValues(forKeys: Set(keys))
            guard values?.isDirectory == true, values?.isPackage != true else { continue }
            out.append(FolderInfo(url: u, name: u.lastPathComponent,
                                  relativePath: relativePath(of: u, under: root ?? folder)))
        }
        return out.sorted { a, b in
            let c = a.name.localizedStandardCompare(b.name)
            if c != .orderedSame { return c == .orderedAscending }
            return a.url.path < b.url.path
        }
    }

    /// サブフォルダを再帰的にすべて列挙する(深さは起点直下を 0 とする。名前順でなく階層順)。
    public static func allSubfolders(of folder: URL, maxDepth: Int = 8) -> [FolderInfo] {
        var out: [FolderInfo] = []
        func walk(_ dir: URL, depth: Int) {
            guard depth <= maxDepth else { return }
            for sub in subfolders(of: dir, root: folder) {
                out.append(sub)
                walk(sub.url, depth: depth + 1)
            }
        }
        walk(folder, depth: 0)
        return out
    }

    /// ファイルを所属フォルダ(相対パス)ごとにまとめる。ルート("")が先、フォルダ内は名前順。
    public static func groupedByFolder(_ items: [Item]) -> [(folder: String, items: [Item])] {
        var groups: [String: [Item]] = [:]
        for item in items { groups[item.directoryPath, default: []].append(item) }
        let folders = groups.keys.sorted { a, b in
            if a.isEmpty != b.isEmpty { return a.isEmpty }
            let c = a.localizedStandardCompare(b)
            if c != .orderedSame { return c == .orderedAscending }
            return a < b
        }
        return folders.map { (folder: $0, items: sorted(groups[$0] ?? [])) }
    }

    /// 素材の長さと、開けるかを調べる(読み込みは非同期)。画像は画像として開けるかだけ。
    /// 開けない・映像や音声のトラックが無い・例外が出たものは `unreadable` になる。
    public static func probe(url: URL, kind: ClipType) async -> (duration: Double?, unreadable: Bool) {
        if kind == .image {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0,
                  CGImageSourceCreateImageAtIndex(src, 0, nil) != nil else { return (nil, true) }
            return (nil, false)
        }
        let asset = AVURLAsset(url: url)
        do {
            let playable = try await asset.load(.isReadable)
            let tracks = try await asset.load(.tracks)
            let seconds = try await asset.load(.duration).seconds
            let hasMedia = tracks.contains { $0.mediaType == .video || $0.mediaType == .audio }
            guard playable, hasMedia else { return (nil, true) }
            return (seconds.isFinite && seconds > 0 ? seconds : nil, false)
        } catch {
            return (nil, true)
        }
    }

    /// `probe` の結果を一覧の 1 行に反映した新しい値。
    public static func applying(_ probed: (duration: Double?, unreadable: Bool), to item: Item) -> Item {
        var i = item
        i.duration = probed.duration
        i.unreadable = probed.unreadable
        return i
    }
}
