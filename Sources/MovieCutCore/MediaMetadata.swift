import Foundation

// MARK: - 素材メタデータ／キーワード／評価／スマートコレクション
//
// Premiere Pro の「メタデータ／ラベル／評価」とスマートコレクション相当の段階実装。
// 素材の同一性は、既存の `mediaHints` / `mediaFingerprints` / `proxyLinks` と同じく
// 「プロジェクトが参照する文字列(`Clip.src` / `mediaPool` の値)」をキーにする。
// そのため再リンクでパスが差し替わると、メタデータは旧パスのキーに残る(再リンク側の
// 追随は未対応。docs/素材メタデータとスマートコレクション.md 参照)。
//
// 保存の作法(既存に倣う):
// - 使っていないプロジェクトでは `mediaMetadata` / `smartCollections` のキーを一切書かない
//   (従来の保存バイトと完全一致)。
// - 値がある項目だけを書く(空のキーワード列・未評価・空メモ・ラベルなしは書かない)。
// - 知らないキーは各構造体の `extra` に保持して書き戻す。

/// 素材のラベル色(Premiere のラベル相当)。なしは `MediaMetadata.label == nil` で表す。
public enum MediaLabelColor: String, CaseIterable, Equatable, Sendable {
    case red, orange, yellow, green, blue, purple, gray

    public var title: String {
        switch self {
        case .red: return "赤"
        case .orange: return "オレンジ"
        case .yellow: return "黄"
        case .green: return "緑"
        case .blue: return "青"
        case .purple: return "紫"
        case .gray: return "グレー"
        }
    }

    /// 0xRRGGBB(表示側が色にする)。
    public var hex: UInt32 {
        switch self {
        case .red: return 0xff5c5c
        case .orange: return 0xffa13d
        case .yellow: return 0xffd84f
        case .green: return 0x5ccf6a
        case .blue: return 0x4f8cff
        case .purple: return 0xb07cff
        case .gray: return 0x9a9eab
        }
    }

    /// 保存された文字列を色にする。空・未知の値は nil(値そのものは `MediaMetadata.label` に残る)。
    public static func resolved(_ raw: String?) -> MediaLabelColor? {
        raw.flatMap { MediaLabelColor(rawValue: $0) }
    }
}

/// 素材 1 件のメタデータ。キーワード(複数)・評価(0〜5、nil は未評価)・メモ・ラベル色。
public struct MediaMetadata: Codable, Equatable, Sendable {
    /// キーワード(タグ)。前後の空白は取り除き、空と重複(大文字小文字を無視)は除く。
    public var keywords: [String] = []
    /// 評価(0〜5)。nil は未評価。範囲外は 0〜5 に収める。
    public var rating: Int? = nil
    /// メモ(説明文)。空(空白だけ)は nil として扱う。
    public var note: String? = nil
    /// ラベル色(`MediaLabelColor` の raw 値)。nil はラベルなし。未知の値はそのまま残す。
    public var label: String? = nil
    /// 知らないキー(保持して書き戻す)。
    public var extra: [String: JSONValue] = [:]

    static let knownKeys: Set<String> = ["keywords", "rating", "note", "label"]
    /// 1 素材あたりのキーワード数の上限(読み込み時の安全策)。
    public static let maxKeywords = 100
    /// キーワード 1 件の長さの上限(文字数)。
    public static let maxKeywordLength = 100
    /// メモの長さの上限(文字数)。
    public static let maxNoteLength = 4000

    public init(keywords: [String] = [], rating: Int? = nil, note: String? = nil, label: String? = nil) {
        self.keywords = keywords
        self.rating = rating
        self.note = note
        self.label = label
        self = normalized
    }

    /// 何も持っていないか(このとき保存では項目ごと書かない)。
    public var isEmpty: Bool {
        keywords.isEmpty && rating == nil && (note ?? "").isEmpty && (label ?? "").isEmpty && extra.isEmpty
    }

    /// 値を安全な形に整えたもの(キーワードの掃除、評価の範囲、メモとラベルの空の除去)。
    public var normalized: MediaMetadata {
        var m = self
        var seen = Set<String>()
        m.keywords = keywords.compactMap { raw -> String? in
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return nil }
            // 重複の判定は切り詰めた後の文字列でする(切り詰めで同じになるものを両方残すと、
            // 保存・再読込の再正規化で片方が消えて件数が変わる)。
            let truncated = String(t.prefix(Self.maxKeywordLength))
            let key = truncated.lowercased()
            guard seen.insert(key).inserted else { return nil }
            return truncated
        }
        if m.keywords.count > Self.maxKeywords { m.keywords = Array(m.keywords.prefix(Self.maxKeywords)) }
        if let r = rating { m.rating = min(max(r, 0), 5) }
        if let n = note {
            let t = n.trimmingCharacters(in: .whitespacesAndNewlines)
            m.note = t.isEmpty ? nil : String(n.prefix(Self.maxNoteLength))
        }
        if let l = label, l.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { m.label = nil }
        return m
    }

    public init(from decoder: Decoder) throws {
        let l = Lenient(c: try decoder.container(keyedBy: AnyKey.self), known: Self.knownKeys)
        keywords = l.value("keywords") ?? []
        rating = l.int("rating")
        note = l.string("note")
        label = l.string("label")
        extra = l.extra()
        self = normalized
        // 型が違って読めなかった項目は、捨てずにそのまま書き戻す
        if keywords.isEmpty, let raw: JSONValue = l.value("keywords"), raw != .array([]) { extra["keywords"] = raw }
        if rating == nil, let raw: JSONValue = l.value("rating") { extra["rating"] = raw }
        if note == nil, let raw: JSONValue = l.value("note") { extra["note"] = raw }
        if label == nil, let raw: JSONValue = l.value("label") { extra["label"] = raw }
    }

    public func encode(to encoder: Encoder) throws {
        let m = normalized
        var c = encoder.container(keyedBy: AnyKey.self)
        for (k, v) in m.extra { try c.encode(v, forKey: AnyKey(k)) }
        if !m.keywords.isEmpty { try c.encode(m.keywords, forKey: AnyKey("keywords")) }
        try c.encodeIfPresent(m.rating, forKey: AnyKey("rating"))
        if let n = m.note, !n.isEmpty { try c.encode(n, forKey: AnyKey("note")) }
        if let l = m.label, !l.isEmpty { try c.encode(l, forKey: AnyKey("label")) }
    }
}

/// キーワード条件の合わせ方。`all` は AND(すべて含む)、`any` は OR(いずれかを含む)。
public enum KeywordMatchMode: String, Codable, CaseIterable, Equatable, Sendable {
    case all, any

    public var title: String {
        switch self {
        case .all: return "すべて含む"
        case .any: return "いずれか含む"
        }
    }
}

/// 絞り込み条件(素材ブラウザの絞り込みと、スマートコレクションの条件を兼ねる)。
///
/// 一致の意味(AND / OR の約束):
/// - **項目の間は AND**: キーワード条件・評価の下限・ラベル・種類・自由文のすべてを満たすときだけ一致する。
/// - **キーワード条件の中**は `keywordMode` で決まる: `.all` は AND(指定したキーワードをすべて持つ)、
///   `.any` は OR(どれか 1 つでも持てばよい)。
/// - **自由文(`text`)の中は AND**: 空白で分けた語をすべて含むこと。各語は「ファイル名・キーワードの
///   どれか・メモ」のどこかに部分一致すればよい(語と欄の間は OR)。
/// - 評価の下限(`minRating`)があるとき、未評価の素材は一致しない(下限 0 のときは未評価も一致する)。
/// - 条件がすべて空のときは、すべての素材に一致する。
public struct MediaFilterCriteria: Codable, Equatable, Sendable {
    public var keywords: [String] = []
    public var keywordMode: KeywordMatchMode = .all
    /// 評価の下限(0〜5)。nil は評価で絞らない。
    public var minRating: Int? = nil
    /// ラベル色(`MediaLabelColor` の raw 値)。nil はラベルで絞らない。未知の値も文字列として比べる。
    public var label: String? = nil
    /// 種類(`ClipType` の raw 値: "video" / "audio" / "image")。nil は種類で絞らない。
    public var kind: String? = nil
    /// 自由文(ファイル名・キーワード・メモを対象にする)。
    public var text: String = ""
    /// 知らないキー(保持して書き戻す)。
    public var extra: [String: JSONValue] = [:]

    static let knownKeys: Set<String> = ["keywords", "keywordMode", "minRating", "label", "kind", "text"]

    public init(keywords: [String] = [], keywordMode: KeywordMatchMode = .all, minRating: Int? = nil,
                label: String? = nil, kind: String? = nil, text: String = "") {
        self.keywords = keywords
        self.keywordMode = keywordMode
        self.minRating = minRating
        self.label = label
        self.kind = kind
        self.text = text
        self = normalized
    }

    /// 種類を `ClipType` で見る(nil は絞らない。未知の値は nil として扱い、文字列のまま比べる側を使う)。
    public var kindType: ClipType? { kind.flatMap { ClipType(rawValue: $0) } }

    /// 条件がすべて空か(このとき保存では条件のキーを書かない)。
    public var isEmpty: Bool {
        keywords.isEmpty && minRating == nil && (label ?? "").isEmpty && (kind ?? "").isEmpty
            && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && extra.isEmpty
    }

    public var normalized: MediaFilterCriteria {
        var c = self
        // キーワードの掃除は MediaMetadata と同じ規則
        c.keywords = MediaMetadata(keywords: keywords).keywords
        if let r = minRating { c.minRating = min(max(r, 0), 5) }
        if let l = label, l.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { c.label = nil }
        if let k = kind, k.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { c.kind = nil }
        return c
    }

    /// 素材 1 件が条件に合うか。`metadata` はその素材のメタデータ(無ければ nil = すべて未設定)。
    public func matches(name: String, kind itemKind: ClipType?, metadata: MediaMetadata?) -> Bool {
        let c = normalized
        let meta = metadata?.normalized ?? MediaMetadata()
        // 種類(AND の 1 項目)
        if let want = c.kind, !want.isEmpty {
            guard let itemKind, itemKind.rawValue == want else { return false }
        }
        // ラベル(AND の 1 項目)
        if let want = c.label, !want.isEmpty {
            guard meta.label == want else { return false }
        }
        // 評価の下限(AND の 1 項目)。下限が正のとき未評価は不一致、下限 0 は未評価も一致。
        if let minR = c.minRating {
            if let r = meta.rating {
                guard r >= minR else { return false }
            } else if minR > 0 {
                return false
            }
        }
        // キーワード条件(中は keywordMode: all = AND / any = OR)
        if !c.keywords.isEmpty {
            let owned = Set(meta.keywords.map { $0.lowercased() })
            let wanted = c.keywords.map { $0.lowercased() }
            switch c.keywordMode {
            case .all: guard wanted.allSatisfy({ owned.contains($0) }) else { return false }
            case .any: guard wanted.contains(where: { owned.contains($0) }) else { return false }
            }
        }
        // 自由文(語の間は AND、各語は 名前・キーワード・メモ のどこかに一致すればよい)
        let terms = c.text.split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { !$0.isEmpty }
        if !terms.isEmpty {
            let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
            func hit(_ haystack: String, _ term: String) -> Bool {
                haystack.range(of: term, options: opts) != nil
            }
            for term in terms {
                let ok = hit(name, term) || meta.keywords.contains { hit($0, term) } || (meta.note.map { hit($0, term) } ?? false)
                guard ok else { return false }
            }
        }
        return true
    }

    public init(from decoder: Decoder) throws {
        let l = Lenient(c: try decoder.container(keyedBy: AnyKey.self), known: Self.knownKeys)
        keywords = l.value("keywords") ?? []
        keywordMode = (l.string("keywordMode").flatMap(KeywordMatchMode.init(rawValue:))) ?? .all
        minRating = l.int("minRating")
        label = l.string("label")
        kind = l.string("kind")
        text = l.string("text") ?? ""
        extra = l.extra()
        self = normalized
        if keywords.isEmpty, let raw: JSONValue = l.value("keywords"), raw != .array([]) { extra["keywords"] = raw }
        if l.string("keywordMode") != nil, KeywordMatchMode(rawValue: l.string("keywordMode") ?? "") == nil,
           let raw: JSONValue = l.value("keywordMode") { extra["keywordMode"] = raw }
        if minRating == nil, let raw: JSONValue = l.value("minRating") { extra["minRating"] = raw }
    }

    public func encode(to encoder: Encoder) throws {
        let c0 = normalized
        var c = encoder.container(keyedBy: AnyKey.self)
        for (k, v) in c0.extra { try c.encode(v, forKey: AnyKey(k)) }
        if !c0.keywords.isEmpty { try c.encode(c0.keywords, forKey: AnyKey("keywords")) }
        if !c0.keywords.isEmpty, c0.keywordMode != .all { try c.encode(c0.keywordMode.rawValue, forKey: AnyKey("keywordMode")) }
        try c.encodeIfPresent(c0.minRating, forKey: AnyKey("minRating"))
        if let l = c0.label, !l.isEmpty { try c.encode(l, forKey: AnyKey("label")) }
        if let k = c0.kind, !k.isEmpty { try c.encode(k, forKey: AnyKey("kind")) }
        if !c0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { try c.encode(c0.text, forKey: AnyKey("text")) }
    }
}

/// スマートコレクション: 名前付きの絞り込み条件。条件に合う素材を、その都度自動で集める
/// (素材そのもののコピーは持たない。条件だけを保存する)。
public struct SmartCollection: Codable, Equatable, Identifiable, Sendable {
    public var id: String = newId()
    public var name: String = ""
    public var criteria: MediaFilterCriteria = MediaFilterCriteria()
    /// 知らないキー(保持して書き戻す)。
    public var extra: [String: JSONValue] = [:]

    static let knownKeys: Set<String> = ["id", "name", "criteria"]

    public init(name: String, criteria: MediaFilterCriteria) {
        self.name = name
        self.criteria = criteria
    }

    public init(id: String, name: String, criteria: MediaFilterCriteria) {
        self.id = id
        self.name = name
        self.criteria = criteria
    }

    /// 素材 1 件がこのコレクションに入るか。
    public func matches(name: String, kind: ClipType?, metadata: MediaMetadata?) -> Bool {
        criteria.matches(name: name, kind: kind, metadata: metadata)
    }

    public init(from decoder: Decoder) throws {
        let l = Lenient(c: try decoder.container(keyedBy: AnyKey.self), known: Self.knownKeys)
        id = l.string("id") ?? id
        name = l.string("name") ?? name
        criteria = l.value("criteria") ?? MediaFilterCriteria()
        extra = l.extra()
        if criteria.isEmpty, let raw: JSONValue = l.value("criteria"), raw != .object([:]) { extra["criteria"] = raw }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        for (k, v) in extra { try c.encode(v, forKey: AnyKey(k)) }
        try c.encode(id, forKey: AnyKey("id"))
        try c.encode(name, forKey: AnyKey("name"))
        if !criteria.isEmpty { try c.encode(criteria, forKey: AnyKey("criteria")) }
    }
}

// MARK: - 編集と絞り込み(純粋な計算。UI と Undo は App 側が `edit` 経由で担う)

public enum MediaMetadataEditing {
    /// 素材のメタデータ(無ければ nil)。
    public static func metadata(for src: String, in project: Project) -> MediaMetadata? {
        project.mediaMetadata[src]?.normalized
    }

    /// 素材のメタデータを丸ごと差し替える。空になったら項目ごと消す(保存にキーが残らない)。
    public static func set(_ metadata: MediaMetadata, for src: String, in project: inout Project) {
        let m = metadata.normalized
        if m.isEmpty { project.mediaMetadata[src] = nil } else { project.mediaMetadata[src] = m }
    }

    /// 素材のメタデータを部分的に変える(渡した欄だけを差し替える)。
    /// `rating` / `note` / `label` は「nil で消す」と「変えない」を区別するため Optional の Optional で受ける。
    public static func update(for src: String, in project: inout Project,
                              keywords: [String]? = nil, rating: Int?? = nil,
                              note: String?? = nil, label: String?? = nil) {
        var m = project.mediaMetadata[src] ?? MediaMetadata()
        if let keywords { m.keywords = keywords }
        if let rating { m.rating = rating }
        if let note { m.note = note }
        if let label { m.label = label }
        set(m, for: src, in: &project)
    }

    /// キーワードを 1 件足す(既にある・空なら何もしない)。
    public static func addKeyword(_ keyword: String, for src: String, in project: inout Project) {
        var m = project.mediaMetadata[src] ?? MediaMetadata()
        m.keywords.append(keyword)
        set(m, for: src, in: &project)
    }

    /// キーワードを 1 件外す(大文字小文字を無視して比べる)。
    public static func removeKeyword(_ keyword: String, for src: String, in project: inout Project) {
        guard var m = project.mediaMetadata[src] else { return }
        let key = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        m.keywords.removeAll { $0.lowercased() == key }
        set(m, for: src, in: &project)
    }

    /// 素材のメタデータをすべて消す。
    public static func clear(for src: String, in project: inout Project) {
        project.mediaMetadata[src] = nil
    }

    /// プロジェクト内で使われているキーワードすべて(重複なし、使用回数が多い順、同数は名前順)。
    public static func allKeywords(in project: Project) -> [String] {
        var counts: [String: Int] = [:]
        var display: [String: String] = [:]
        for m in project.mediaMetadata.values {
            for k in m.keywords {
                let key = k.lowercased()
                counts[key, default: 0] += 1
                if display[key] == nil { display[key] = k }
            }
        }
        return counts.keys.sorted { a, b in
            if counts[a]! != counts[b]! { return counts[a]! > counts[b]! }
            return display[a]!.localizedStandardCompare(display[b]!) == .orderedAscending
        }.map { display[$0]! }
    }

    /// プロジェクトが参照する素材(`mediaPool` とクリップの `src` の和集合、出てきた順)のうち、
    /// 条件に合うものの `src` 一覧。種類はファイル名から決める(`MediaBrowser.kind`)。
    public static func filteredSources(in project: Project, criteria: MediaFilterCriteria) -> [String] {
        MediaFingerprintCollector.referencedSources(in: project).filter { src in
            let name = (src as NSString).lastPathComponent
            let kind = MediaBrowser.kind(forName: name)
            return criteria.matches(name: name, kind: kind, metadata: project.mediaMetadata[src])
        }
    }

    /// スマートコレクションに合う素材の `src` 一覧(出てきた順)。
    public static func sources(in project: Project, matching collection: SmartCollection) -> [String] {
        filteredSources(in: project, criteria: collection.criteria)
    }

    /// スマートコレクションを足す(同名でも別物として足す)。足したコレクションを返す。
    @discardableResult
    public static func addCollection(name: String, criteria: MediaFilterCriteria, in project: inout Project) -> SmartCollection {
        let c = SmartCollection(name: name, criteria: criteria)
        project.smartCollections.append(c)
        return c
    }

    /// スマートコレクションを差し替える(id で探す)。無ければ何もしない。
    public static func updateCollection(_ collection: SmartCollection, in project: inout Project) {
        guard let i = project.smartCollections.firstIndex(where: { $0.id == collection.id }) else { return }
        project.smartCollections[i] = collection
    }

    /// スマートコレクションを消す(id で探す)。
    public static func removeCollection(id: String, in project: inout Project) {
        project.smartCollections.removeAll { $0.id == id }
    }
}

// MARK: - 素材ブラウザとの接続(ファイル一覧 + プロジェクトのメタデータ)

extension MediaBrowser {
    /// ファイル一覧を、プロジェクトのメタデータ(キーはファイルのパス)で絞る。
    /// 種類・名前検索は既存の `filter` と同じで、そのうえに `criteria` を AND で重ねる。
    /// `criteria` が空なら既存の `filter` と同じ結果になる。
    public static func filter(_ items: [Item], kind: KindFilter, query: String, sort: SortKey = .name,
                              metadata: [String: MediaMetadata], criteria: MediaFilterCriteria) -> [Item] {
        filter(items, kind: kind, query: query, sort: sort).filter { item in
            criteria.matches(name: item.name, kind: item.kind, metadata: metadata[item.url.path])
        }
    }
}
