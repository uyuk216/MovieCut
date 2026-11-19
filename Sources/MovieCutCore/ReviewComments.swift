import Foundation

/// レビューコメント(Frame.io 等価のローカル実現)。タイムコード付きの指摘をプロジェクト内に保持し、
/// 交換用 JSON / CSV ファイルで他の人・他の道具とやり取りする。クラウド送信は一切しない。
/// 保存の作法はマーカーと同じ: 任意項目は既定値のとき書かず、未知のキーは `extra` に保持して書き戻す。
public struct ReviewComment: Codable, Equatable, Identifiable {
    public var id: String = newId()
    /// タイムライン上の位置(秒、0 以上)。
    public var time: Double = 0
    /// 範囲の終わり(秒)。nil = 1 点へのコメント。`time` より前なら nil として扱う。
    public var endTime: Double? = nil
    /// 本文。
    public var body: String = ""
    /// 作成者名(表示名。アカウントやメールアドレスではない)。
    public var author: String = ""
    /// 対象クリップの id(任意)。クリップが消えてもコメントは残る(参照が切れるだけ)。
    public var clipId: String? = nil
    /// 解決済みかどうか。false のときはファイルに書かない。
    public var resolved: Bool = false
    /// 作成日時(ISO 8601 文字列、任意。並び替えには使わない)。
    public var createdAt: String? = nil
    /// 更新日時(ISO 8601 文字列、任意)。
    public var updatedAt: String? = nil
    public var extra: [String: JSONValue] = [:]

    static let knownKeys: Set<String> = ["id", "time", "endTime", "body", "author", "clipId", "resolved", "createdAt", "updatedAt"]

    public init() {}
    public init(time: Double, body: String, author: String = "") {
        self.time = max(0, time.isFinite ? time : 0)
        self.body = body
        self.author = author
    }

    public init(from decoder: Decoder) throws {
        let l = Lenient(c: try decoder.container(keyedBy: AnyKey.self), known: Self.knownKeys)
        id = l.string("id") ?? id
        let t = l.double("time") ?? 0
        time = t.isFinite ? max(0, t) : 0
        if let e = l.double("endTime"), e.isFinite, e > time { endTime = e }
        body = l.string("body") ?? body
        author = l.string("author") ?? author
        clipId = l.string("clipId").flatMap { $0.isEmpty ? nil : $0 }
        resolved = l.bool("resolved") ?? false
        createdAt = l.string("createdAt").flatMap { $0.isEmpty ? nil : $0 }
        updatedAt = l.string("updatedAt").flatMap { $0.isEmpty ? nil : $0 }
        extra = l.extra()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        for (k, v) in extra { try c.encode(v, forKey: AnyKey(k)) }
        try c.encode(id, forKey: AnyKey("id"))
        try c.encode(time, forKey: AnyKey("time"))
        try c.encodeIfPresent(endTime, forKey: AnyKey("endTime"))
        try c.encode(body, forKey: AnyKey("body"))
        if !author.isEmpty { try c.encode(author, forKey: AnyKey("author")) }
        try c.encodeIfPresent(clipId, forKey: AnyKey("clipId"))
        if resolved { try c.encode(true, forKey: AnyKey("resolved")) }
        try c.encodeIfPresent(createdAt, forKey: AnyKey("createdAt"))
        try c.encodeIfPresent(updatedAt, forKey: AnyKey("updatedAt"))
    }

    /// 範囲コメントかどうか。
    public var hasRange: Bool { endTime != nil }
}

/// レビューコメントの純粋な編集(UI にも Undo にも依存しない)。
public enum ReviewCommentEditing {
    /// 時刻順(同じ時刻は元の順)。
    public static func sorted(_ comments: [ReviewComment]) -> [ReviewComment] {
        comments.enumerated().sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }.map(\.element)
    }

    /// コメントを足す。本文が空(空白のみ)なら足さず nil を返す。足したコメントの id も返す。
    public static func add(in project: Project, at t: Double, body: String, author: String = "",
                           endTime: Double? = nil, clipId: String? = nil,
                           createdAt: String? = nil) -> (project: Project, id: String)? {
        let b = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !b.isEmpty else { return nil }
        var c = ReviewComment(time: t, body: b, author: author.trimmingCharacters(in: .whitespacesAndNewlines))
        if let e = endTime, e.isFinite, e > c.time { c.endTime = e }
        c.clipId = clipId.flatMap { $0.isEmpty ? nil : $0 }
        c.createdAt = createdAt
        var p = project
        p.reviewComments.append(c)
        p.reviewComments = ReviewCommentEditing.sorted(p.reviewComments)
        return (p, c.id)
    }

    /// 本文を差し替える。空にはしない(空なら変えず nil)。
    public static func updateBody(in project: Project, id: String, to body: String, updatedAt: String? = nil) -> Project? {
        guard let i = project.reviewComments.firstIndex(where: { $0.id == id }) else { return nil }
        let b = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !b.isEmpty, b != project.reviewComments[i].body else { return nil }
        var p = project
        p.reviewComments[i].body = b
        if let updatedAt { p.reviewComments[i].updatedAt = updatedAt }
        return p
    }

    /// 解決済みフラグを切り替える。既にその状態なら nil。
    public static func setResolved(in project: Project, id: String, to resolved: Bool, updatedAt: String? = nil) -> Project? {
        guard let i = project.reviewComments.firstIndex(where: { $0.id == id }),
              project.reviewComments[i].resolved != resolved else { return nil }
        var p = project
        p.reviewComments[i].resolved = resolved
        if let updatedAt { p.reviewComments[i].updatedAt = updatedAt }
        return p
    }

    public static func remove(in project: Project, id: String) -> Project? {
        guard project.reviewComments.contains(where: { $0.id == id }) else { return nil }
        var p = project
        p.reviewComments.removeAll { $0.id == id }
        return p
    }

    /// 未解決の数。
    public static func openCount(in project: Project) -> Int {
        project.reviewComments.count { !$0.resolved }
    }
}

/// レビューコメントの交換ファイル(JSON が正、CSV は書き出し専用の閲覧用)。
/// 形式: `{ "format": "moviecut-review-comments", "version": 1, "exportedAt": "...", "comments": [ ... ] }`
/// 読み込みは素の配列 `[ ... ]` も受け付ける(他の道具が作った一覧を取り込めるように)。
public enum ReviewCommentExchange {
    public static let formatName = "moviecut-review-comments"
    public static let formatVersion = 1

    public struct MergeResult: Equatable {
        public var project: Project
        public var added: Int
        public var updated: Int
        public var unchanged: Int
    }

    public enum ExchangeError: Error, Equatable {
        case notReviewCommentFile
        case unsupportedVersion(Int)
    }

    /// 交換用 JSON を作る(キーは整列、コメントは時刻順。人間が読める字下げ付き)。
    public static func encodeJSON(_ comments: [ReviewComment], exportedAt: String? = nil) throws -> Data {
        var root: [String: JSONValue] = [
            "format": .string(formatName),
            "version": .number(Double(formatVersion)),
            "comments": .array(try ReviewCommentEditing.sorted(comments).map { try encodeValue($0) }),
        ]
        if let exportedAt { root["exportedAt"] = .string(exportedAt) }
        let data = try JSONEncoder().encode(JSONValue.object(root))
        // JSONValue の符号化は整列を保証しないので、辞書経由で整形し直す
        let obj = try JSONSerialization.jsonObject(with: data)
        return try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private static func encodeValue<T: Encodable>(_ v: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(v))
    }

    /// 交換用 JSON を読む。形式が違うものは `ExchangeError` で断る(黙って空にしない)。
    public static func decodeJSON(_ data: Data) throws -> [ReviewComment] {
        let raw = try JSONSerialization.jsonObject(with: data)
        if let arr = raw as? [Any] {
            return try decodeComments(arr)
        }
        guard let obj = raw as? [String: Any], let fmt = obj["format"] as? String, fmt == formatName else {
            throw ExchangeError.notReviewCommentFile
        }
        if let v = (obj["version"] as? NSNumber)?.intValue, v > formatVersion {
            throw ExchangeError.unsupportedVersion(v)
        }
        guard let arr = obj["comments"] as? [Any] else { throw ExchangeError.notReviewCommentFile }
        return try decodeComments(arr)
    }

    private static func decodeComments(_ arr: [Any]) throws -> [ReviewComment] {
        let data = try JSONSerialization.data(withJSONObject: arr)
        return try JSONDecoder().decode([ReviewComment].self, from: data)
    }

    /// 読み込んだコメントをプロジェクトへ反映する。
    /// 競合規則: **同じ id があれば読み込んだ側で上書き、新しい id は追加、交換ファイルに無い既存コメントは消さない**。
    /// 内容がまったく同じ id は「変更なし」に数える。結果は時刻順に並べ直す。
    public static func merge(into project: Project, incoming: [ReviewComment]) -> MergeResult {
        var p = project
        var added = 0, updated = 0, unchanged = 0
        var indexById: [String: Int] = [:]
        for (i, c) in p.reviewComments.enumerated() { indexById[c.id] = i }
        for c in incoming {
            if let i = indexById[c.id] {
                if p.reviewComments[i] == c { unchanged += 1 } else { p.reviewComments[i] = c; updated += 1 }
            } else {
                indexById[c.id] = p.reviewComments.count
                p.reviewComments.append(c)
                added += 1
            }
        }
        p.reviewComments = ReviewCommentEditing.sorted(p.reviewComments)
        return MergeResult(project: p, added: added, updated: updated, unchanged: unchanged)
    }

    /// CSV(閲覧・表計算用)。列: id, timecode, time(秒), endTime(秒), author, resolved, clipId, body。
    /// 本文中の改行・引用符・カンマは RFC 4180 式に引用する。
    public static func csv(_ comments: [ReviewComment]) -> String {
        var lines = ["id,timecode,time,endTime,author,resolved,clipId,body"]
        for c in ReviewCommentEditing.sorted(comments) {
            let row: [String] = [
                c.id,
                Chapters.timecode(c.time),
                String(c.time),
                c.endTime.map { String($0) } ?? "",
                c.author,
                c.resolved ? "resolved" : "open",
                c.clipId ?? "",
                c.body,
            ]
            lines.append(row.map(csvField).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func csvField(_ s: String) -> String {
        guard s.contains(",") || s.contains("\"") || s.contains("\n") else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
