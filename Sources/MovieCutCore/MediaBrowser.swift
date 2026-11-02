import Foundation

// MARK: - 素材ブラウザの一覧(種類・検索・並べ替え・フォルダの走査)

/// 素材ブラウザの純粋ロジック。画面は持たない。
/// 対象の拡張子は `ClipEditing` の一覧と同じ(ここで一覧に出たものは「タイムラインに追加」できる)。
/// サブフォルダ・隠しファイル・通常のファイルでないものは飛ばす。
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

    /// 一覧の 1 行(ファイル 1 つ)。
    public struct Item: Equatable, Identifiable, Sendable {
        public let url: URL
        public let name: String
        public let kind: ClipType
        public var id: String { url.path }

        public init(url: URL, name: String, kind: ClipType) {
            self.url = url
            self.name = name
            self.kind = kind
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
        items.sorted { a, b in
            let c = a.name.localizedStandardCompare(b.name)
            if c != .orderedSame { return c == .orderedAscending }
            return a.url.path < b.url.path
        }
    }

    /// 種類で絞り、検索語を名前に含むものだけを残して、自然順に並べる。
    /// 検索は大文字小文字・全角半角・濁点の違いを無視する。空白だけの検索語は「全部」と同じ。
    public static func filter(_ items: [Item], kind: KindFilter, query: String) -> [Item] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let hits = items.filter { item in
            guard kind.matches(item.kind) else { return false }
            if q.isEmpty { return true }
            return item.name.range(of: q, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil
        }
        return sorted(hits)
    }

    /// フォルダ直下の対象ファイルを一覧にする(同期・長さは測らない)。フォルダが無い・読めないときは空。
    public static func scan(folder: URL) -> [Item] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return []
        }
        var out: [Item] = []
        for u in urls {
            guard let k = kind(forName: u.lastPathComponent) else { continue }
            // 通常のファイルでないもの(フォルダ・壊れたリンク)は除く
            guard (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            out.append(Item(url: u, name: u.lastPathComponent, kind: k))
        }
        return sorted(out)
    }
}
