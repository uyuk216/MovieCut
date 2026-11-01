import Foundation

/// カラオケ字幕(単語・文字の色つけ)。文字の装飾(`TextStyle.highlight`)の一部として保存する。未設定 = しない。
/// 話している部分の文字を `color` で塗り、クリップの頭から終わりまでに時間で増やす。
public struct Highlight: Codable, Equatable, Sendable {
    /// 色つけした文字の色(#RRGGBB)。未設定 = `#ffd54a`。
    public var color: String?
    /// "char"(1 文字ずつ・既定)/ "word"(空白までの単位ごと)。
    public var mode: String?
    /// 任意: 単位ごとの開始秒(クリップの頭から)。単位の数が一致するときだけ使い、無ければ字数で割る。
    public var times: [Double]?
    public var extra: [String: JSONValue] = [:]
    static let knownKeys: Set<String> = ["color", "mode", "times"]
    public static let defaultColor = "#ffd54a"

    public init(color: String? = nil, mode: String? = nil, times: [Double]? = nil) {
        self.color = color; self.mode = mode; self.times = times
    }

    public init(from decoder: Decoder) throws {
        let l = Lenient(c: try decoder.container(keyedBy: AnyKey.self), known: Self.knownKeys)
        color = l.string("color"); mode = l.string("mode")
        times = l.value("times")
        extra = l.extra()
        if let raw: JSONValue = l.value("times"), times == nil { extra["times"] = raw }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        for (k, v) in extra { try c.encode(v, forKey: AnyKey(k)) }
        try c.encodeIfPresent(color, forKey: AnyKey("color"))
        try c.encodeIfPresent(mode, forKey: AnyKey("mode"))
        try c.encodeIfPresent(times, forKey: AnyKey("times"))
    }

    public var colorOrDefault: String { color.flatMap { parseHexColorString($0) ? $0 : nil } ?? Self.defaultColor }
    public var isWordMode: Bool { mode == "word" }

    /// 範囲に収めた写し(時刻は負・非有限を捨てる。色は不正なら既定に戻す)。
    public var normalized: Highlight {
        var h = self
        if let c = color, !parseHexColorString(c) { h.color = nil }
        if let m = mode, m != "char", m != "word" { h.mode = nil }
        if let ts = times { let ok = ts.allSatisfy { $0.isFinite && $0 >= 0 }; h.times = ok && !ts.isEmpty ? ts : nil }
        return h
    }
}

/// 色をつける字数の計算(画面にも描画にも依存しない)。
public enum KaraokeMath {
    /// 1 単位: 字数(改行を除いた文字数)と、字の重み(空白は 0)。
    struct Unit { var length: Int; var weight: Int }

    /// 単位の列。char は 1 文字ずつ、word は「空白でない並び + 直後の空白」を 1 単位にする。改行は数えない。
    static func units(_ text: String, wordMode: Bool) -> [Unit] {
        let chars = text.filter { $0 != "\n" }
        guard wordMode else { return chars.map { Unit(length: 1, weight: $0.isWhitespace ? 0 : 1) } }
        var out: [Unit] = []
        var len = 0, w = 0, sawSpaceAfterWord = false
        for ch in chars {
            if ch.isWhitespace {
                len += 1
                if w > 0 { sawSpaceAfterWord = true }
            } else {
                // 語のあとに空白があって、次の語が始まったら、単位を区切る
                if sawSpaceAfterWord { out.append(Unit(length: len, weight: w)); len = 0; w = 0; sawSpaceAfterWord = false }
                len += 1; w += 1
            }
        }
        if len > 0 { out.append(Unit(length: len, weight: w)) }
        return out
    }

    /// 時刻 `rel`(クリップの頭から)に色をつける字数。全体の字数以下。`duration` を過ぎたら全部。
    public static func coloredCount(text: String, highlight: Highlight, rel: Double, duration: Double) -> Int {
        let us = units(text, wordMode: highlight.isWordMode)
        let total = us.reduce(0) { $0 + $1.length }
        guard total > 0, rel.isFinite else { return 0 }
        if rel <= 0 { return 0 }
        guard duration > 0, rel < duration else { return total }
        // 任意の単位ごとの開始秒: 単位の数が一致するときだけ使う
        if let ts = highlight.times, ts.count == us.count {
            var n = 0
            for (i, u) in us.enumerated() where ts[i] <= rel { n += u.length }
            return n
        }
        // 字数(重み)で時間に比例して増やす。単位の途中では色をつけない。
        let weightTotal = us.reduce(0) { $0 + $1.weight }
        guard weightTotal > 0 else { return 0 }
        let target = Double(weightTotal) * min(max(rel / duration, 0), 1)
        var cum = 0.0, n = 0
        for u in us {
            cum += Double(u.weight)
            guard cum <= target + 1e-9 else { break }
            n += u.length
        }
        return n
    }
}

/// 色の書式(#RRGGBB か #RGB)を確かめる。描画の色の読み取り(parseHexColor)と同じ範囲。
func parseHexColorString(_ s: String) -> Bool {
    var h = s.trimmingCharacters(in: .whitespaces)
    if h.hasPrefix("#") { h.removeFirst() }
    return (h.count == 6 || h.count == 3) && h.allSatisfy { $0.isHexDigit }
}
