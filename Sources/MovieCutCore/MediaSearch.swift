import Foundation

// MARK: - メディアインテリジェンス検索 第 1 段(文字起こし文による素材内検索)
//
// Premiere Pro の「メディアインテリジェンス／素材の自然言語検索」の段階実装。
// 第 1 段は、すでに文字起こし済みの素材について「話している内容の文」で
// プロジェクト内の素材を横断検索し、一致した文の開始位置(素材内時刻)へ案内する。
// 画像の埋め込み照合(「キーボードを打つ手」のような映像内容の検索)は第 2 段で、
// ここでは扱わない。ただし索引の項目(`MediaSearch.Entry`)は `kind` を持ち、
// 第 2 段で映像特徴の項目を同じ索引へ足せる形にしてある。
//
// 保存の考え方(既存の作法に合わせた判断。詳細は docs/メディアインテリジェンス検索.md):
// - 文字起こし結果そのものは、従来どおりプロジェクトファイルには保存されない
//   (認識は都度実行し、字幕・書き出し・テキスト編集へ流すのが既存の流れ)。
// - そこで検索の元になる文字起こしは、素材ファイルごとの「再構築可能なキャッシュ」
//   (`MediaTranscriptStore`)に持つ。素材が変わったら目印(サイズ・更新日時)で
//   古いと分かり、その素材は対象外に戻る。消えても、もう一度文字起こしすれば戻る。
// - 索引(`MediaSearch.Index`)は保存せず、検索のたびにキャッシュから組み立てる。

// MARK: - 文字起こしのキャッシュ(素材ファイルごと・再構築可能)

/// 文字起こし結果の保存庫。素材の実パスをキーに、文の列(素材の頭からの秒)を JSON で持つ。
/// 保存・読み込みはスレッドセーフ。ファイルが無い・壊れているときは空として扱う(作り直せる)。
public final class MediaTranscriptStore: @unchecked Sendable {
    /// 保存する文 1 件(素材の頭からの秒)。
    public struct Segment: Codable, Equatable, Sendable {
        public var text: String
        public var start: Double
        public var end: Double
        public init(text: String, start: Double, end: Double) {
            self.text = text; self.start = start; self.end = end
        }
    }

    private struct Entry: Codable, Equatable {
        var size: Int64
        /// 更新日時(ミリ秒に丸めた timeIntervalSince1970)。読めなかったときは nil。
        var modified: Double?
        var segments: [Segment]
    }

    private struct FileBody: Codable {
        var version: Int = 1
        var entries: [String: Entry] = [:]
    }

    private let fileURL: URL
    private let stampProvider: (String) -> MediaFingerprintCache.FileStamp?
    private let lock = NSLock()
    private var loaded: FileBody?

    /// `stamp` は差し替えられる(テスト用。既定はファイルを実際に見る)。
    public init(fileURL: URL,
                stamp: @escaping (String) -> MediaFingerprintCache.FileStamp? = MediaFingerprintCache.fileStamp(atPath:)) {
        self.fileURL = fileURL
        self.stampProvider = stamp
    }

    /// 既定の保存先(`DataLocations.transcriptCache`)。
    public static var standard: MediaTranscriptStore {
        MediaTranscriptStore(fileURL: DataLocations.current.transcriptCache)
    }

    /// 登録している素材の数(確認・テスト用)。
    public var count: Int { lock.withLock { loadLocked().entries.count } }

    /// 登録している素材のパス一覧(並びは問わない)。
    public var registeredPaths: [String] { lock.withLock { Array(loadLocked().entries.keys) } }

    /// 素材の文字起こし。未登録・素材が変わっている(目印が合わない)ときは nil。
    /// 目印が合わない記録は捨てる(その素材は「文字起こしなし」に戻る)。
    public func segments(forPath path: String) -> [TranscriptSegment]? {
        lock.withLock {
            var body = loadLocked()
            guard let entry = body.entries[path] else { return nil }
            guard let now = stampProvider(path), Self.stampMatches(entry, now) else {
                body.entries[path] = nil
                saveLocked(body)
                return nil
            }
            return entry.segments.map { TranscriptSegment(text: $0.text, start: $0.start, end: $0.end) }
        }
    }

    /// 文字起こし結果を登録する(素材の頭からの秒で渡す)。
    /// 同じ素材に既にある文とは重ねて持ち(重複は除く)、部分的な範囲の文字起こしを
    /// 何度かに分けて足していける。素材が変わっていたら、古い文は捨ててから足す。
    /// 空の文・時刻が壊れている文は入れない。
    public func register(path: String, segments: [TranscriptSegment]) {
        let cleaned: [Segment] = segments.compactMap { s in
            let text = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, s.start.isFinite, s.end.isFinite else { return nil }
            return Segment(text: text, start: s.start, end: max(s.start, s.end))
        }
        guard !cleaned.isEmpty else { return }
        lock.withLock {
            var body = loadLocked()
            let now = stampProvider(path)
            var merged: [Segment] = []
            if let entry = body.entries[path], let now, Self.stampMatches(entry, now) {
                merged = entry.segments
            }
            for s in cleaned where !merged.contains(s) { merged.append(s) }
            merged.sort { ($0.start, $0.end, $0.text) < ($1.start, $1.end, $1.text) }
            body.entries[path] = Entry(size: now?.size ?? -1,
                                       modified: Self.stampKey(now?.modified),
                                       segments: merged)
            saveLocked(body)
        }
    }

    /// 素材の記録を消す。
    public func remove(path: String) {
        lock.withLock {
            var body = loadLocked()
            guard body.entries[path] != nil else { return }
            body.entries[path] = nil
            saveLocked(body)
        }
    }

    private static func stampKey(_ date: Date?) -> Double? {
        date.map { ($0.timeIntervalSince1970 * 1000).rounded() / 1000 }
    }

    private static func stampMatches(_ entry: Entry, _ now: MediaFingerprintCache.FileStamp) -> Bool {
        entry.size == now.size && entry.modified == stampKey(now.modified)
    }

    private func loadLocked() -> FileBody {
        if let loaded { return loaded }
        var body = FileBody()
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(FileBody.self, from: data),
           decoded.version == 1 {
            body = decoded
        }
        loaded = body
        return body
    }

    private func saveLocked(_ body: FileBody) {
        loaded = body
        guard let data = try? JSONEncoder().encode(body) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: [.atomic])
    }
}

// MARK: - 索引と検索

public enum MediaSearch {
    /// 索引の項目の種類。第 1 段は文字起こしのみ。第 2 段で映像特徴(埋め込み照合)を足す。
    public enum EntryKind: String, Codable, Equatable, Sendable {
        case transcript
    }

    /// 検索対象の素材 1 件(プロジェクトが参照する動画・音声)。
    public struct MediaItem: Equatable, Sendable, Identifiable {
        /// プロジェクト内の参照文字列(`Clip.src` / `mediaPool` の値)。
        public var src: String
        /// 解決済みの実パス(解決できなければ `src` そのもの)。
        public var path: String
        /// ファイル名(表示用)。
        public var name: String
        public var kind: ClipType
        /// 文字起こしがあり、検索の対象になるか。
        public var hasTranscript: Bool
        /// 索引に入っている文の数。
        public var segmentCount: Int
        public var id: String { src }
        public init(src: String, path: String, name: String, kind: ClipType, hasTranscript: Bool, segmentCount: Int) {
            self.src = src; self.path = path; self.name = name; self.kind = kind
            self.hasTranscript = hasTranscript; self.segmentCount = segmentCount
        }
    }

    /// 索引の項目 1 件(文 1 件)。時刻は素材の頭からの秒。
    public struct Entry: Equatable, Sendable {
        public var kind: EntryKind
        public var src: String
        public var path: String
        public var start: Double
        public var end: Double
        public var text: String
        public init(kind: EntryKind, src: String, path: String, start: Double, end: Double, text: String) {
            self.kind = kind; self.src = src; self.path = path
            self.start = start; self.end = end; self.text = text
        }
    }

    /// 検索できる状態(素材の一覧 + 項目の列)。保存はせず、使うたびに組み立てる。
    public struct Index: Equatable, Sendable {
        public var media: [MediaItem]
        public var entries: [Entry]
        public init(media: [MediaItem], entries: [Entry]) {
            self.media = media; self.entries = entries
        }
        /// 文字起こしが無く、検索の対象外の素材(画面で「対象外」と分かるように出す)。
        public var untranscribed: [MediaItem] { media.filter { !$0.hasTranscript } }
        /// 検索できる素材があるか。
        public var hasSearchableMedia: Bool { media.contains { $0.hasTranscript } }
    }

    /// 一致 1 件。素材 + 文の開始位置(素材の頭からの秒)で示す。
    public struct Hit: Equatable, Sendable, Identifiable {
        public var src: String
        public var path: String
        public var mediaName: String
        /// 文の開始位置(素材の頭からの秒)。
        public var start: Double
        public var end: Double
        public var text: String
        public var kind: EntryKind
        public var id: String { "\(src)#\(start)#\(text)" }
        public init(src: String, path: String, mediaName: String, start: Double, end: Double, text: String, kind: EntryKind) {
            self.src = src; self.path = path; self.mediaName = mediaName
            self.start = start; self.end = end; self.text = text; self.kind = kind
        }
    }

    /// ヒットをタイムラインへ対応づけた位置。
    public struct TimelineLocation: Equatable, Sendable {
        public var clipId: String
        /// タイムライン上の時刻(秒)。
        public var time: Double
        public init(clipId: String, time: Double) { self.clipId = clipId; self.time = time }
    }

    /// プロジェクトの素材(動画・音声のみ。画像は対象外)から索引を組み立てる。
    /// `transcripts` は実パス → 文の列(`MediaTranscriptStore` から集めたもの)。
    /// パスの解決は `MediaFingerprintCollector` と同じ作法(`MediaResolver` → 差し替え可能な `resolve` → `src` そのもの)。
    public static func buildIndex(project: Project, projectDir: String? = nil,
                                  transcripts: [String: [TranscriptSegment]],
                                  resolve: (String) -> String? = { _ in nil }) -> Index {
        var media: [MediaItem] = []
        var entries: [Entry] = []
        for src in MediaFingerprintCollector.referencedSources(in: project) {
            guard let kind = MediaBrowser.kind(forName: (src as NSString).lastPathComponent),
                  kind == .video || kind == .audio else { continue }
            let path = MediaResolver.resolve(src: src, projectDir: projectDir) ?? resolve(src) ?? src
            let segments = transcripts[path] ?? []
            media.append(MediaItem(src: src, path: path, name: (path as NSString).lastPathComponent,
                                   kind: kind, hasTranscript: !segments.isEmpty, segmentCount: segments.count))
            for s in segments {
                entries.append(Entry(kind: .transcript, src: src, path: path, start: s.start, end: s.end, text: s.text))
            }
        }
        return Index(media: media, entries: entries)
    }

    /// 検索。検索語を空白で分け、すべての語を含む文を一致とする(部分一致)。
    /// 表記ゆれの扱いは `normalize` にそろえる(かな・全角半角・大文字小文字・句読点や空白の有無)。
    /// 結果は素材名 → 開始位置の順。空の検索語では何も返さない。
    public static func search(_ query: String, in index: Index) -> [Hit] {
        let terms = query.split(whereSeparator: { $0.isWhitespace })
            .map { normalize(String($0)) }
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return [] }
        let names = Dictionary(index.media.map { ($0.src, $0.name) }, uniquingKeysWith: { a, _ in a })
        return index.entries
            .filter { entry in
                let body = normalize(entry.text)
                return terms.allSatisfy { body.contains($0) }
            }
            .map { entry in
                Hit(src: entry.src, path: entry.path, mediaName: names[entry.src] ?? (entry.path as NSString).lastPathComponent,
                    start: entry.start, end: entry.end, text: entry.text, kind: entry.kind)
            }
            .sorted { ($0.mediaName, $0.start, $0.text) < ($1.mediaName, $1.start, $1.text) }
    }

    /// 検索の表記ゆれを吸収する正規化。
    /// - 全角英数 → 半角、半角カタカナ → 全角カタカナ、英字は小文字(`folding` の width / case / diacritic)
    /// - カタカナ → ひらがな(「キーボード」と「きーぼーど」を同じにする。長音「ー」はそのまま)
    /// - 空白と句読点などの記号は取り除く(「行きます。」と「行きます」を同じにする)
    public static func normalize(_ s: String) -> String {
        let folded = s.folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: nil)
        var out = String.UnicodeScalarView()
        for scalar in folded.unicodeScalars {
            // カタカナ(ァ〜ヶ)をひらがなへずらす
            if (0x30A1...0x30F6).contains(scalar.value) {
                out.append(Unicode.Scalar(scalar.value - 0x60)!)
                continue
            }
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { continue }
            if CharacterSet.punctuationCharacters.contains(scalar) { continue }
            out.append(scalar)
        }
        return String(out)
    }

    /// ヒット(素材内時刻)を、タイムライン上の位置へ対応づける。
    /// その素材を使っているクリップのうち、素材時刻とタイムライン時刻が 1 対 1 のもの
    /// (`TranscriptionSupport` と同じ条件)で、ヒットの開始位置を含むものを探す。
    /// 見つからなければ nil(素材が未配置、または速度変更などで対応づけられない)。
    public static func timelineLocation(for hit: Hit, in project: Project) -> TimelineLocation? {
        var best: TimelineLocation?
        for clip in project.allClips where clip.src == hit.src {
            guard TranscriptionSupport.supports(clip) else { continue }
            let local = hit.start - clip.offset
            guard local >= 0, local <= clip.duration else { continue }
            let candidate = TimelineLocation(clipId: clip.id, time: clip.start + local)
            if best == nil || candidate.time < best!.time { best = candidate }
        }
        return best
    }
}
