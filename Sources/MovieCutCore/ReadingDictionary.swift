import Foundation

// MARK: - 読み辞書
//
// セリフの「表記」を、音声合成に渡す「読み(かな)」へ置き換える辞書。
// 本人の運用(誤読しやすい語だけ かな にした読み上げ文を別に用意する)を、ソフト側で自動化するための土台。
//
// - 置き場はプロジェクト(`Project.readingDictionary`)。使ったときだけファイルに書く(古いファイルはそのまま開ける)。
// - 適用は台本から声を作るとき(`ScriptTimeline.add`)に 1 回だけ行い、結果をボイスクリップの読み上げ文にする。
//   音声の作り直しは読み上げ文から合成するので、辞書をあとから変えても既存クリップの読みは勝手に変わらない。
// - 字幕は元の表記のまま(読み上げ文と字幕文が分かれる)。字幕文が別に指定されている行はそちらが優先。

/// 品詞(VOICEVOX user_dict の word_type と同じ値)。
public enum ReadingPartOfSpeech: String, Codable, CaseIterable, Sendable {
    case properNoun = "PROPER_NOUN"
    case commonNoun = "COMMON_NOUN"
    case verb = "VERB"
    case adjective = "ADJECTIVE"
    case suffix = "SUFFIX"

    public var label: String {
        switch self {
        case .properNoun: return "固有名詞"
        case .commonNoun: return "普通名詞"
        case .verb: return "動詞"
        case .adjective: return "形容詞"
        case .suffix: return "接尾辞"
        }
    }
}

/// 読み辞書の 1 件(表記 → 読み)。
public struct ReadingEntry: Codable, Equatable, Sendable {
    /// 置き換える表記(例: 「相棒」)。
    public var word: String
    /// 読み(例: 「あいぼう」)。
    public var reading: String
    /// アクセント型(VOICEVOX user_dict の accent_type。0=平板、n=n モーラ目の後で下がる)。nil なら未指定(同期時は 0)。
    public var accentType: Int?
    /// 品詞(VOICEVOX user_dict の word_type)。nil なら未指定(同期時は固有名詞)。
    public var partOfSpeech: ReadingPartOfSpeech?
    /// 優先度(VOICEVOX user_dict の priority、0〜10)。nil なら未指定(同期時は 5)。
    public var priority: Int?

    public init(word: String, reading: String, accentType: Int? = nil, partOfSpeech: ReadingPartOfSpeech? = nil, priority: Int? = nil) {
        self.word = word
        self.reading = reading
        self.accentType = accentType
        self.partOfSpeech = partOfSpeech
        self.priority = priority
    }
}

public enum ReadingDictionary {
    /// 読み上げ文に辞書を適用する。
    /// - 長い表記から優先して照合する(同点は辞書の並び順)。置き換えた部分は再照合しない。
    /// - 先頭の表情タグ `[名前]` の中は変換しない。何も置き換わらなければ元の文をそのまま返す。
    public static func apply(to text: String, entries: [ReadingEntry]) -> String {
        let valid = entries.filter { !$0.word.isEmpty && !$0.reading.isEmpty }
        guard !valid.isEmpty, !text.isEmpty else { return text }
        let (tag, body) = ExpressionTag.split(text)
        let converted = convert(body, entries: valid)
        guard converted != body else { return text }
        if let tag { return "[\(tag)]" + converted }
        return converted
    }

    static func convert(_ body: String, entries: [ReadingEntry]) -> String {
        // 長い順(同点は辞書の並び順を保つ)
        let sorted = entries.enumerated()
            .sorted { a, b in a.element.word.count != b.element.word.count ? a.element.word.count > b.element.word.count : a.offset < b.offset }
            .map(\.element)
        var result = ""
        result.reserveCapacity(body.count)
        var i = body.startIndex
        while i < body.endIndex {
            let rest = body[i...]
            if let hit = sorted.first(where: { rest.hasPrefix($0.word) }) {
                result += hit.reading
                i = body.index(i, offsetBy: hit.word.count)
            } else {
                result.append(body[i])
                i = body.index(after: i)
            }
        }
        return result
    }

    /// 画面・ファイルから入れた列を整える: 表記・読みが空の件を除き、同じ表記は最初の 1 件だけ残す。
    public static func normalized(_ entries: [ReadingEntry]) -> [ReadingEntry] {
        var seen = Set<String>()
        return entries.filter { e in
            guard !e.word.isEmpty, !e.reading.isEmpty, !seen.contains(e.word) else { return false }
            seen.insert(e.word)
            return true
        }
    }

    // MARK: テキスト形式(辞書ファイル・画面の編集でも使う共通形式)
    //
    // 1 行 1 件: 「表記,読み」「表記\t読み」「表記=読み」のどれか。# か ※ で始まる行はコメント、空行は無視。
    // 同じ表記が複数あれば最初の 1 件だけを使う。

    /// 辞書テキストを読む。読めない行は飛ばす。
    public static func parse(text: String) -> [ReadingEntry] {
        var out: [ReadingEntry] = []
        var seen = Set<String>()
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("※") { continue }
            guard let sep = line.firstIndex(where: { $0 == "," || $0 == "\t" || $0 == "=" }) else { continue }
            let word = line[line.startIndex..<sep].trimmingCharacters(in: .whitespaces)
            let reading = line[line.index(after: sep)...].trimmingCharacters(in: .whitespaces)
            guard !word.isEmpty, !reading.isEmpty, !seen.contains(word) else { continue }
            seen.insert(word)
            out.append(ReadingEntry(word: word, reading: reading))
        }
        return out
    }

    /// 辞書テキストに書き出す(「表記,読み」を 1 行ずつ)。
    public static func serialized(_ entries: [ReadingEntry]) -> String {
        entries.map { "\($0.word),\($0.reading)" }.joined(separator: "\n")
    }
}
