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

    /// 1 プロジェクトあたりのコメント数の上限(読み込み時の安全策。`InputLimits` の sanitize と交換読み込みで使う)。
    public static let maxCount = 10_000
    /// 本文の長さの上限(文字数。素材メタデータのメモと同じ 4000)。
    public static let maxBodyLength = 4000
    /// 作成者名の長さの上限(文字数)。
    public static let maxAuthorLength = 100

    /// 交換ファイルや引数から入る時刻の整形(非有限は 0、巨大な有限値も表示側の整数変換で落ちない上限へ)。
    public static func sanitizedTime(_ t: Double) -> Double { t.isFinite ? min(max(0, t), 1.0e12) : 0 }

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
        time = ReviewComment.sanitizedTime(t)
        if let e = l.double("endTime"), e.isFinite, e > time { endTime = ReviewComment.sanitizedTime(e) }
        body = String((l.string("body") ?? body).prefix(Self.maxBodyLength))
        author = String((l.string("author") ?? author).prefix(Self.maxAuthorLength))
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
        var c = ReviewComment(time: ReviewComment.sanitizedTime(t),
                              body: String(b.prefix(ReviewComment.maxBodyLength)),
                              author: String(author.trimmingCharacters(in: .whitespacesAndNewlines).prefix(ReviewComment.maxAuthorLength)))
        if let e = endTime { let se = ReviewComment.sanitizedTime(e); if se > c.time { c.endTime = se } }
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
        p.reviewComments[i].body = String(b.prefix(ReviewComment.maxBodyLength))
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
        project.reviewComments.filter { !$0.resolved }.count
    }

    /// 解決済みの数。
    public static func resolvedCount(in project: Project) -> Int {
        project.reviewComments.filter { $0.resolved }.count
    }
}

/// レビューコメントの交換ファイル(JSON が正、CSV も読み書きできる)。
/// 形式: `{ "format": "moviecut-review-comments", "version": 1, "exportedAt": "...", "comments": [ ... ] }`
/// 読み込みは素の配列 `[ ... ]` も受け付ける(他の道具が作った一覧を取り込めるように)。
/// CSV は `createdAt` / `updatedAt` と未知のキー(`extra`)を持たないので、往復の正は JSON とする。
public enum ReviewCommentExchange {
    public static let formatName = "moviecut-review-comments"
    public static let formatVersion = 1
    /// 交換ファイル 1 件の大きさの上限(字幕ファイルと同じ 8MB)。
    public static let maxExchangeBytes = 8 * 1024 * 1024

    public struct MergeResult: Equatable {
        public var project: Project
        public var added: Int
        public var updated: Int
        public var unchanged: Int
    }

    public enum ExchangeError: Error, Equatable, LocalizedError {
        case notReviewCommentFile
        case unsupportedVersion(Int)
        public var errorDescription: String? {
            switch self {
            case .notReviewCommentFile: return "レビューコメントの交換ファイルとして読み取れませんでした"
            case .unsupportedVersion(let v): return "この交換ファイルは新しい形式(バージョン \(v))で、このアプリでは読み込めません"
            }
        }
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
        let decoded = try JSONDecoder().decode([ReviewComment].self, from: data)
        return Array(decoded.prefix(ReviewComment.maxCount))
    }

    // MARK: 形式の自動判定・ファイル読み込み

    /// 交換ファイルの中身から形式を見分けて読む(先頭が `{` / `[` なら JSON、それ以外は CSV)。
    /// CSV として読んだ結果が 0 件で、本文のある行が 1 つも無いときは `ExchangeError` で断る(関係ないテキストを黙って空にしない)。
    public static func decodeExchange(_ data: Data) throws -> [ReviewComment] {
        let rawText = String(decoding: data, as: UTF8.self)
        var text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        // JSON は前後の空白と BOM を落とした文字列から読む(CSV は元の文字列をそのまま渡す)
        if text.hasPrefix("{") || text.hasPrefix("[") { return try decodeJSON(Data(text.utf8)) }
        let comments = decodeCSV(rawText)
        guard !comments.isEmpty else { throw ExchangeError.notReviewCommentFile }
        return comments
    }

    /// 交換ファイルを大きさの上限つきで読む(`InputLimits` の作法)。
    public static func read(from url: URL) throws -> [ReviewComment] {
        let data = try InputLimits.readFile(url, limit: maxExchangeBytes, what: "レビューコメントの交換ファイル")
        return try decodeExchange(data)
    }

    // MARK: CSV

    /// タイムコード文字列を読む: `65` / `65.5`(秒)、`1:05`、`1:02:03.5` のどれでもよい。小数の区切りは `.` と `,` の両方可。
    /// 読めない・負・非有限なら nil。
    public static func parseTimecode(_ raw: String) -> Double? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count <= 3 else { return nil }
        var total = 0.0
        for (i, part) in parts.enumerated() {
            let isLast = i == parts.count - 1
            let piece = isLast ? part.replacingOccurrences(of: ",", with: ".") : String(part)
            guard let v = Double(piece), v.isFinite, v >= 0 else { return nil }
            if !isLast, v != v.rounded() { return nil }
            total = total * 60 + v
        }
        return total.isFinite ? total : nil
    }

    /// CSV を読む。見出し行があれば列名(英語・日本語)で対応づけ、無ければ書き出しと同じ列順
    /// (id, timecode, time, endTime, author, resolved, clipId, body)とみなす。
    /// 本文が空の行・列が足りない行は捨てる。`time` 列が読めなければ `timecode` 列から復元する。
    /// `id` が無い行には新しい id を振る。件数は上限で切る。
    public static func decodeCSV(_ text: String) -> [ReviewComment] {
        let noBom = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        var rows = ScriptCSV.rows(fromCSV: noBom)
        guard !rows.isEmpty else { return [] }

        // 既定は書き出しの列順
        var idx: [String: Int] = ["id": 0, "timecode": 1, "time": 2, "endTime": 3, "author": 4, "resolved": 5, "clipId": 6, "body": 7]
        let aliases: [String: String] = [
            "id": "id", "timecode": "timecode", "タイムコード": "timecode",
            "time": "time", "time(秒)": "time", "秒": "time", "時刻(秒)": "time",
            "endtime": "endTime", "endtime(秒)": "endTime", "終わり(秒)": "endTime",
            "author": "author", "作成者": "author", "作成者名": "author", "作者": "author",
            "resolved": "resolved", "解決済み": "resolved", "状態": "resolved",
            "clipid": "clipId", "対象クリップ": "clipId", "クリップ": "clipId",
            "body": "body", "本文": "body", "コメント": "body",
        ]
        if let head = rows.first {
            let names = head.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            let mapped = names.compactMap { aliases[$0] }
            // 見出しらしい行(既知の列名が 2 つ以上、または body/id を含む)なら対応づけ直して行を落とす
            if mapped.count >= 2 || mapped.contains("body") || mapped.contains("id") {
                var m: [String: Int] = [:]
                for (i, n) in names.enumerated() { if let key = aliases[n], m[key] == nil { m[key] = i } }
                idx = m
                rows.removeFirst()
            }
        }
        guard let bodyIdx = idx["body"] else { return [] }
        func cell(_ row: [String], _ key: String) -> String {
            guard let i = idx[key], row.indices.contains(i) else { return "" }
            return row[i].trimmingCharacters(in: .whitespaces)
        }
        var out: [ReviewComment] = []
        for row in rows {
            guard row.indices.contains(bodyIdx) else { continue }
            let body = row[bodyIdx].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            var c = ReviewComment()
            let id = cell(row, "id")
            if !id.isEmpty { c.id = id }
            c.time = ReviewComment.sanitizedTime(Double(cell(row, "time")) ?? parseTimecode(cell(row, "timecode")) ?? parseTimecode(cell(row, "time")) ?? 0)
            if let e = Double(cell(row, "endTime")), e.isFinite, e > c.time { c.endTime = ReviewComment.sanitizedTime(e) }
            c.body = String(body.prefix(ReviewComment.maxBodyLength))
            c.author = String(cell(row, "author").prefix(ReviewComment.maxAuthorLength))
            let clip = cell(row, "clipId")
            c.clipId = clip.isEmpty ? nil : clip
            let r = cell(row, "resolved").lowercased()
            c.resolved = ["resolved", "true", "1", "yes", "済", "解決済み"].contains(r)
            out.append(c)
            if out.count >= ReviewComment.maxCount { break }
        }
        return out
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
        // 読み込み時の上限と同じにそろえる(保存・再読込で黙って消えないように)
        if p.reviewComments.count > ReviewComment.maxCount { p.reviewComments = Array(p.reviewComments.prefix(ReviewComment.maxCount)) }
        return MergeResult(project: p, added: added, updated: updated, unchanged: unchanged)
    }

    /// CSV(読み書き両用)。列: id, timecode, time(秒), endTime(秒), author, resolved, clipId, body。
    /// 既存の CSV 書き出し(使用クリップ一覧・注記一覧)と同じ作法: 先頭に UTF-8 の BOM、行末は CRLF、
    /// 引用は RFC 4180 式(`ClipListingExport.csvCell`)。`timecode` は表示用(秒未満は切り捨て)で、
    /// 正確な時刻は `time` 列が持つ。`createdAt` / `updatedAt` / 未知のキーは CSV には出ない。
    public static func csv(_ comments: [ReviewComment]) -> String {
        let rows = [["id", "timecode", "time", "endTime", "author", "resolved", "clipId", "body"]] + ReviewCommentEditing.sorted(comments).map { c in
            [c.id,
             Chapters.timecode(c.time),
             String(c.time),
             c.endTime.map { String($0) } ?? "",
             c.author,
             c.resolved ? "resolved" : "open",
             c.clipId ?? "",
             c.body]
        }
        return "\u{FEFF}" + rows.map { row in row.map(ClipListingExport.csvCell).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }
}
