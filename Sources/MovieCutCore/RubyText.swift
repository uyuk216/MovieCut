import Foundation

// MARK: - ルビ(ふりがな)
//
// 文字・字幕の親文字の上に、小さい読みを出すための土台。
// - 置き場はクリップ(`Clip.ruby`)。空のときはファイルに書かない(古いファイルはそのまま開ける)。
// - span は「親文字の文字列」と「読み」だけを持ち、位置は描くときに本文から前から順に探して決める
//   (`resolve`)。読み辞書(`ReadingDictionary`)と同じ流儀で、本文を少し直しても位置がずれにくい。
// - 取り込み: 字幕ファイルの `<ruby>親<rt>読み</rt></ruby>` を保持する(`SubtitleFile`)。以前は読みを捨てていた。
// - 書き出し: VTT には `<ruby>` で書き戻す。SRT には書き方が無いので親文字だけ。
// - 描画は横書きの通常経路だけ(縦書き・文字ごとのアニメーションのときはルビを出さない)。
//   読みの大きさは親文字の 0.5 倍、行間には親文字の 0.62 倍の余白を足す(`Renderer.drawText` / `textBlockSize`)。

/// ルビ 1 件(親文字 → 読み)。
public struct RubySpan: Codable, Equatable, Hashable, Sendable {
    /// 親文字(本文の中の文字列。例: 「相棒」)。
    public var base: String
    /// 読み(例: 「あいぼう」)。
    public var reading: String

    public init(base: String, reading: String) {
        self.base = base
        self.reading = reading
    }
}

public enum RubyText {
    /// 読みの大きさ(親文字の大きさに対する割合)。
    public static let sizeRatio = 0.5
    /// ルビのある行に足す行間の余白(親文字の大きさに対する割合)。
    public static let pitchReserveRatio = 0.62

    /// 位置を決めたルビ(Character 単位の範囲)。
    public struct Resolved: Equatable, Sendable {
        public var start: Int
        /// 終わり(この位置は含まない)。
        public var end: Int
        public var reading: String
        public init(start: Int, end: Int, reading: String) {
            self.start = start; self.end = end; self.reading = reading
        }
    }

    /// span を本文の前から順に探して位置を決める。
    /// 見つからない span、親文字・読みが空の span は捨てる。探す位置は前に決まった span の後ろから
    /// (同じ親文字が何度も出ても、span の並び順に対応する現れ方へ 1 つずつ割り当てる)。
    public static func resolve(_ spans: [RubySpan], in text: String) -> [Resolved] {
        let chars = Array(text)
        var out: [Resolved] = []
        var cursor = 0
        for span in spans {
            let base = Array(span.base)
            guard !base.isEmpty, !span.reading.isEmpty, base.count <= chars.count - cursor else { continue }
            var found: Int?
            var i = cursor
            while i + base.count <= chars.count {
                if chars[i..<(i + base.count)].elementsEqual(base) { found = i; break }
                i += 1
            }
            guard let s = found else { continue }
            out.append(Resolved(start: s, end: s + base.count, reading: span.reading))
            cursor = s + base.count
        }
        return out
    }

    // MARK: 字幕ファイルの <ruby> 書き方

    private static let rubyBlock = try! NSRegularExpression(pattern: #"(?is)<ruby\b[^>]*>(.*?)</ruby\s*>"#)
    private static let rtBlock = try! NSRegularExpression(pattern: #"(?is)<rt\b[^>]*>(.*?)</rt\s*>"#)
    private static let rpBlock = try! NSRegularExpression(pattern: #"(?is)<rp\b[^>]*>.*?</rp\s*>"#)
    private static let anyTag = try! NSRegularExpression(pattern: #"</?[A-Za-z][^>]*>"#)

    private static func stripTags(_ s: String) -> String {
        anyTag.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "")
    }

    /// `<ruby>親<rt>読み</rt></ruby>`(括弧の `<rp>` つきも)を、親文字だけの文字列と span の列に分ける。
    /// ruby でない部分はそのまま。閉じタグが無いなど壊れた書き方は触らずに残す(後段のタグ除去に任せる)。
    public static func extractMarkup(_ s: String) -> (plain: String, spans: [RubySpan]) {
        guard s.contains("<ruby") else { return (s, []) }
        let ns = s as NSString
        var spans: [RubySpan] = []
        var out = ""
        var last = 0
        for m in rubyBlock.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let whole = m.range(at: 0)
            out += ns.substring(with: NSRange(location: last, length: whole.location - last))
            let (base, reading) = splitInner(ns.substring(with: m.range(at: 1)))
            out += base
            if !base.isEmpty, let reading, !reading.isEmpty {
                spans.append(RubySpan(base: base, reading: reading))
            }
            last = whole.location + whole.length
        }
        out += ns.substring(from: last)
        return (out, spans)
    }

    /// ruby の中身「親<rp>(</rp><rt>読み</rt><rp>)</rp>」→ (親, 読み)。`<rt>` が無ければ読みは nil。
    static func splitInner(_ inner: String) -> (base: String, reading: String?) {
        let ns = inner as NSString
        var reading: String?
        var base = inner
        if let m = rtBlock.firstMatch(in: inner, range: NSRange(location: 0, length: ns.length)) {
            reading = stripTags(ns.substring(with: m.range(at: 1))).trimmingCharacters(in: .whitespaces)
            base = rtBlock.stringByReplacingMatches(in: inner, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        }
        base = rpBlock.stringByReplacingMatches(in: base, range: NSRange(location: 0, length: (base as NSString).length), withTemplate: "")
        return (stripTags(base), reading)
    }

    /// span を `<ruby>` 書き方に戻す(VTT 書き出し用)。位置が決まらなかった span は無視する。
    public static func markup(_ text: String, spans: [RubySpan]) -> String {
        let rs = resolve(spans, in: text)
        guard !rs.isEmpty else { return text }
        let chars = Array(text)
        var out = ""
        var pos = 0
        for r in rs {
            out += String(chars[pos..<r.start])
            out += "<ruby>" + String(chars[r.start..<r.end]) + "<rt>" + r.reading + "</rt></ruby>"
            pos = r.end
        }
        out += String(chars[pos...])
        return out
    }
}
