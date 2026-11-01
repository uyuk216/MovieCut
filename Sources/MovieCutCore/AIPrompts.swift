import Foundation

// AI に渡すプロンプトの組み立て(送信前に画面へ見せる文)と、返事の読み取り。画面にも通信にも依存しない純粋な処理。

public enum AIText {
    /// ``` で囲まれた部分があればその中身(最初のブロック)。無ければ全体。
    public static func stripFences(_ s: String) -> String {
        var inside = false, found = false
        var block: [String] = []
        for l in s.components(separatedBy: "\n") {
            if l.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inside { found = true; break }
                inside = true; continue
            }
            if inside { block.append(l) }
        }
        if found || (inside && !block.isEmpty) { return block.joined(separator: "\n") }
        return s
    }

    /// 行頭の箇条書き記号・番号・強調の記号を外す。
    static func cleanLine(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespaces)
        t = t.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
        for p in ["- ", "* ", "• ", "・", "> "] where t.hasPrefix(p) { t = String(t.dropFirst(p.count)); break }
        // 「1. 」「1) 」「1、」(「1:30」の時刻は外さない)
        var digits = 0
        for ch in t { if ch.isASCII && ch.isNumber { digits += 1 } else { break } }
        if digits > 0, digits <= 3, let f = t.dropFirst(digits).first, ".)、）".contains(f) {
            t = String(t.dropFirst(digits + 1)).trimmingCharacters(in: .whitespaces)
        }
        return t.trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - a) 台本

public enum AIScriptPrompt {
    public static let maxLines = 200
    public static let lineRange = 2...60

    public struct Request: Equatable {
        public var theme: String
        public var characterNames: [String]
        public var lineCount: Int
        public init(theme: String, characterNames: [String], lineCount: Int) {
            self.theme = theme; self.characterNames = characterNames; self.lineCount = lineCount
        }
    }

    public static func build(_ r: Request) -> String {
        let n = min(max(r.lineCount, lineRange.lowerBound), lineRange.upperBound)
        let names = r.characterNames.joined(separator: "、")
        return """
        あなたは動画の台本を書く作家です。次の条件で、会話形式の台本を書いてください。

        テーマ: \(r.theme.trimmingCharacters(in: .whitespacesAndNewlines))
        登場キャラ: \(names)
        長さ: およそ \(n) 行

        書式のルール(厳守):
        - 1 行に 1 つのセリフ。形式は「キャラ名: セリフ」(キャラ名は上の登場キャラの名前だけを使う)。
        - 見出し、説明、番号、記号、コードブロックは書かない。台本の行だけを出力する。
        - 1 つのセリフは短めに(目安 40 文字以内)。声に出して読める文にする。
        """
    }

    /// 返事を台本の行(「名前: セリフ」)にそろえる。コードブロックや前置き・後書きの文は捨てる。
    /// 名前は既知のキャラだけ(「名前:」で始まらない行は説明文として捨てる)。
    public static func parse(_ response: String, characterNames: [String]) throws -> [String] {
        var lines: [String] = []
        for raw in AIText.stripFences(response).components(separatedBy: .newlines) {
            let l = AIText.cleanLine(raw)
            guard !l.isEmpty, let sep = l.firstIndex(where: { $0 == ":" || $0 == "：" }), sep != l.startIndex else { continue }
            var name = l[l.startIndex..<sep].trimmingCharacters(in: .whitespaces)
            for q in ["「", "」", "[", "]", "【", "】", "(", ")"] { name = name.replacingOccurrences(of: q, with: "") }
            var rest = l[l.index(after: sep)...].trimmingCharacters(in: .whitespaces)
            if rest.hasPrefix("「"), rest.hasSuffix("」"), rest.count >= 2 { rest = String(rest.dropFirst().dropLast()) }
            guard !rest.isEmpty, characterNames.contains(name) else { continue }
            lines.append("\(name): \(rest)")
            if lines.count >= maxLines { break }
        }
        guard !lines.isEmpty else { throw AIError.unparsable("台本の行(「キャラ名: セリフ」)") }
        return lines
    }
}

// MARK: - b) チャプター

public enum AIChapterPrompt {
    public static let maxInputCharacters = 12_000
    public static let maxChapters = 30

    public struct Chapter: Equatable { public var time: Double; public var title: String }

    /// 字幕(開始秒, 文)から作る。長すぎる分は末尾を切る(切ったことは `truncated` で分かる)。
    public static func build(cues: [SubtitleCue], duration: Double) -> (prompt: String, truncated: Bool) {
        var body = "", truncated = false
        for c in cues {
            let line = "[\(Chapters.timecode(c.start))] \(c.text.replacingOccurrences(of: "\n", with: " "))\n"
            if body.count + line.count > maxInputCharacters { truncated = true; break }
            body += line
        }
        let prompt = """
        次は動画の字幕(時刻つき)です。内容の流れを見て、YouTube のチャプターを作ってください。

        動画の長さ: \(Chapters.timecode(duration))

        書式のルール(厳守):
        - 1 行に 1 つ。形式は「m:ss 題名」(1 時間以上は h:mm:ss)。
        - 最初の行は 0:00。3 つ以上、各チャプターは 10 秒以上あける。多くても \(maxChapters) 個まで。
        - 題名は短く(20 文字以内)。説明、番号、記号、コードブロックは書かず、チャプターの行だけを出力する。

        字幕:
        \(body)
        """
        return (prompt, truncated)
    }

    /// `m:ss` / `mm:ss` / `h:mm:ss` を秒にする。
    static func parseTimecode(_ s: Substring) -> Double? {
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.count <= 3 && $0.allSatisfy { $0.isASCII && $0.isNumber } }) else { return nil }
        let v = parts.compactMap { Double($0) }
        guard v.count == parts.count else { return nil }
        if v.count == 2 { return v[1] < 60 ? v[0] * 60 + v[1] : nil }
        return v[1] < 60 && v[2] < 60 ? v[0] * 3600 + v[1] * 60 + v[2] : nil
    }

    /// 返事をチャプターに。時刻順・1 秒以内の重複は先のものを残す・動画の長さを超えるものは捨てる。
    public static func parse(_ response: String, duration: Double) throws -> [Chapter] {
        let trim = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "])】）-–—―:："))
        var items: [Chapter] = []
        for raw in AIText.stripFences(response).components(separatedBy: .newlines) {
            var l = AIText.cleanLine(raw)
            if let f = l.first, "[(【（".contains(f) { l.removeFirst() }
            let end = l.firstIndex(where: { $0.isWhitespace || "])】）-–—―～".contains($0) }) ?? l.endIndex
            guard let t = parseTimecode(l[l.startIndex..<end]) else { continue }
            let title = String(l[end...]).trimmingCharacters(in: trim).trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty, t <= max(duration, 0) + 0.5 else { continue }
            items.append(Chapter(time: t, title: Chapters.title(title)))
        }
        items = items.enumerated().sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }.map(\.element)
        var out: [Chapter] = []
        for c in items where !out.contains(where: { abs($0.time - c.time) < 1 }) { out.append(c) }
        out = Array(out.prefix(maxChapters))
        guard !out.isEmpty else { throw AIError.unparsable("チャプター(「m:ss 題名」の行)") }
        return out
    }

    /// 既存のマーカーに足す形にする(Chapters.make が整形と注意を担当)。
    public static func markers(from chapters: [Chapter]) -> [Marker] { chapters.map { Marker(time: $0.time, name: $0.title) } }
}

// MARK: - d) タイトル案

/// 動画全体のタイトル案(YouTube 向け)。字幕の文とマーカーの名前から作る。送る前に内容を見せる(呼び出し側)。
public enum AITitlePrompt {
    public static let maxInputCharacters = 6_000
    public static let count = 5
    public static let maxTitleLength = 40

    /// 字幕(時刻なし)とマーカーの名前から。長すぎる分は末尾を切る(`truncated` で分かる)。
    public static func build(cues: [SubtitleCue], markerNames: [String]) -> (prompt: String, truncated: Bool) {
        var body = "", truncated = false
        for c in cues {
            let line = c.text.replacingOccurrences(of: "\n", with: " ") + "\n"
            if body.count + line.count > maxInputCharacters { truncated = true; break }
            body += line
        }
        let names = markerNames.filter { !$0.isEmpty }.map { "- \($0)" }.joined(separator: "\n")
        let prompt = """
        次は動画の内容です。YouTube 向けのタイトル案を \(count) 件作ってください。

        書式のルール(厳守):
        - 1 行に 1 つ。番号・記号・説明は付けず、タイトルだけを出力する。
        - 各 \(maxTitleLength) 文字以内。
        - 互いに言い回しや切り口を変える。

        見出し候補(マーカー):
        \(names.isEmpty ? "(なし)" : names)

        字幕:
        \(body.isEmpty ? "(なし)" : body)
        """
        return (prompt, truncated)
    }

    /// 返事の行をタイトルにする。空・重複は捨て、件数は `count` まで。1 件も無ければ例外。
    public static func parse(_ response: String) throws -> [String] {
        var out: [String] = []
        for raw in AIText.stripFences(response).components(separatedBy: .newlines) {
            let t = AIText.cleanLine(raw).trimmingCharacters(in: CharacterSet(charactersIn: "「」『』\"'"))
            guard !t.isEmpty, !out.contains(t) else { continue }
            out.append(t)
        }
        out = Array(out.prefix(count))
        guard !out.isEmpty else { throw AIError.unparsable("タイトル案(1 行に 1 件)") }
        return out
    }
}

// MARK: - c) セリフの言い換え・短縮

public enum AIRewritePrompt {
    public static let maxLength = 300

    public enum Mode: String, CaseIterable, Sendable {
        case paraphrase, shorten, casual
        public var title: String {
            switch self {
            case .paraphrase: return "言い換える"
            case .shorten: return "短くする"
            case .casual: return "くだけた口調にする"
            }
        }
        var instruction: String {
            switch self {
            case .paraphrase: return "意味を変えずに、別の言い回しに言い換えてください。"
            case .shorten: return "意味を保ったまま、できるだけ短くしてください(元より長くしない)。"
            case .casual: return "意味を変えずに、親しみやすいくだけた話し言葉にしてください。"
            }
        }
    }

    public static func build(text: String, characterName: String?, mode: Mode) -> String {
        """
        動画のセリフを直してください。\(mode.instruction)

        話す人: \(characterName ?? "(不明)")
        元のセリフ: \(text)

        書式のルール(厳守):
        - 直したセリフ 1 行だけを出力する。かぎ括弧、キャラ名、説明、候補の複数提示、コードブロックは書かない。
        """
    }

    /// 返事から直したセリフ 1 行を取り出す。
    public static func parse(_ response: String) throws -> String {
        for raw in AIText.stripFences(response).components(separatedBy: .newlines) {
            var l = AIText.cleanLine(raw)
            guard !l.isEmpty else { continue }
            // 「直したセリフ: …」のような前置きを外す
            if let sep = l.firstIndex(where: { $0 == ":" || $0 == "：" }), l.distance(from: l.startIndex, to: sep) <= 8 {
                let head = l[l.startIndex..<sep]
                if ["セリフ", "言い換え", "短縮", "直し", "回答"].contains(where: { head.contains($0) }) {
                    l = l[l.index(after: sep)...].trimmingCharacters(in: .whitespaces)
                }
            }
            if l.count >= 2, let a = l.first, let b = l.last, (a == "「" && b == "」") || (a == "\"" && b == "\"") || (a == "『" && b == "』") {
                l = String(l.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            }
            guard !l.isEmpty else { continue }
            return String(l.prefix(maxLength))
        }
        throw AIError.unparsable("直したセリフ")
    }
}

// MARK: - プロジェクトの要約(読み取り専用。外部の AI が中身を見るため)

public enum ProjectInfo {
    /// JSON(人にも読める整形)。クリップ・長さ・キャラ・セリフを含む。ファイルは変えない。
    public static func json(_ p: Project) throws -> String {
        var clips: [[String: Any]] = []
        for (ti, t) in p.tracks.enumerated() {
            for c in t.clips.sorted(by: { $0.start < $1.start }) {
                var d: [String: Any] = ["layer": ti + 1, "type": c.type.rawValue, "start": round3(c.start), "duration": round3(c.duration), "end": round3(c.start + c.duration)]
                if let text = c.text, !text.isEmpty { d["text"] = text }
                if c.type == .voice, let name = p.characters.first(where: { $0.id == c.charId })?.name { d["character"] = name }
                clips.append(d)
            }
        }
        let obj: [String: Any] = [
            "size": "\(p.width)x\(p.height)", "fps": p.fps, "duration": round3(p.endTime),
            "characters": p.characters.map { ["name": $0.name, "engine": $0.engine] },
            "layers": p.tracks.count, "clipCount": clips.count, "clips": clips,
            "markers": p.markers.map { ["time": round3($0.time), "name": $0.name] },
            "script": p.allClips.filter { $0.type == .voice }.sorted { $0.start < $1.start }.compactMap { c -> String? in
                guard let t = c.text, !t.isEmpty else { return nil }
                return "\(p.characters.first(where: { $0.id == c.charId })?.name ?? "?"): \(t)"
            },
        ]
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    private static func round3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
}
