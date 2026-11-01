import Foundation

// 字幕の翻訳(AI プロバイダ経由)。字幕の文を番号つきで送り、番号つきの返事を読む。時刻はそのまま保つ。
// 送る前に画面で内容を見せる(呼び出し側の askAI が確認する)。画面にも通信にも依存しない純粋な処理。

public enum AITranslatePrompt {
    /// 送る字幕の文字数の上限(これを超えるときは送らず、字幕を分けてもらう)。
    public static let maxInputCharacters = 12_000

    public enum Language: String, CaseIterable, Sendable {
        case english, chineseSimplified, korean
        /// 画面に出す名前
        public var label: String {
            switch self { case .english: return "英語"; case .chineseSimplified: return "中国語（簡体字）"; case .korean: return "韓国語" }
        }
        /// プロンプトに書く言語名(英語)
        var promptName: String {
            switch self { case .english: return "English"; case .chineseSimplified: return "Simplified Chinese"; case .korean: return "Korean" }
        }
        /// 書き出すファイル名に入れる短い名前
        public var fileSuffix: String {
            switch self { case .english: return "英語"; case .chineseSimplified: return "中国語"; case .korean: return "韓国語" }
        }
    }

    public enum BuildError: Error, Equatable { case noCues, tooLong(limit: Int) }

    /// 字幕の文を番号つきで並べたプロンプト。文は 1 行にまとめる(改行は空白に)。字幕が長すぎれば `tooLong`。
    public static func build(cues: [SubtitleCue], language: Language) throws -> String {
        guard !cues.isEmpty else { throw BuildError.noCues }
        var body = ""
        for (i, c) in cues.enumerated() {
            body += "\(i + 1)\t\(c.text.replacingOccurrences(of: "\n", with: " "))\n"
        }
        guard body.count <= maxInputCharacters else { throw BuildError.tooLong(limit: maxInputCharacters) }
        return """
        次は動画の字幕です。各行を\(language.promptName)に翻訳してください。

        ルール(厳守):
        - 入力と同じ数の行を、同じ番号つきで出力する。形式は「番号<TAB>訳文」。
        - 番号を飛ばさない。行を統合・分割しない。説明や前置きは書かない。
        - 固有名詞や記号はできるだけそのまま残す。訳文は 1 行に収める。

        字幕:
        \(body)
        """
    }

    /// 返事を読んで、番号順の訳文にする。番号が 1…expected のどれか欠けていれば `unparsable`(途中の行は捨てずに、全体をやり直してもらう)。
    /// 番号の後ろの区切り(タブ・|・.・:・全角の句読点・空白)は捨てる。同じ番号が 2 回出たら先のものを使う。
    public static func parse(_ response: String, expected: Int) throws -> [String] {
        var out = [String?](repeating: nil, count: expected)
        for raw in AIText.stripFences(response).components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let digits = line.prefix(while: { $0.isASCII && $0.isNumber })
            guard !digits.isEmpty, let n = Int(digits), (1...expected).contains(n) else { continue }
            let rest = line.dropFirst(digits.count).drop(while: { "\t|.:：)）、 　".contains($0) })
            let text = rest.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            if out[n - 1] == nil { out[n - 1] = text }
        }
        guard out.allSatisfy({ $0 != nil }) else { throw AIError.unparsable("翻訳の行(番号 1〜\(expected))") }
        return out.map { $0! }
    }

    /// 時刻と長さはそのまま、文だけを訳文に入れ替えた字幕。
    public static func translated(_ cues: [SubtitleCue], texts: [String]) -> [SubtitleCue] {
        zip(cues, texts).map { SubtitleCue(start: $0.start, end: $0.end, text: $1) }
    }
}
