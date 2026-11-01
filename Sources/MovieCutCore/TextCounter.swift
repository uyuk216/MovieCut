import Foundation

/// 文字クリップのカウントダウン(タイマー)。クリップの頭から終わりまでで `from` から `to` へ直線に変わる数を、
/// `format` の形で文字にする。文字クリップの `text` を前置きにして、その後ろに数を続ける(例: "残り " + "00:10")。
/// 任意項目で、無いとき(nil)は従来どおり `text` だけを出す。
public struct TextCounter: Codable, Equatable, Sendable {
    /// 表示の形: "mm:ss"(分:秒、0 埋め)か "ss"(秒だけ)。
    public static let formats = ["mm:ss", "ss"]
    public static let defaultFormat = "mm:ss"

    public var from: Double
    public var to: Double
    public var format: String

    /// 知らないキー(新しい版が書いた項目)。そのまま書き戻す。
    public var extra: [String: JSONValue] = [:]
    static let knownKeys: Set<String> = ["from", "to", "format"]

    public init(from: Double = 10, to: Double = 0, format: String = TextCounter.defaultFormat) {
        self.from = max(0, from)
        self.to = max(0, to)
        self.format = Self.formats.contains(format) ? format : Self.defaultFormat
    }

    public init(from decoder: Decoder) throws {
        let l = Lenient(c: try decoder.container(keyedBy: AnyKey.self), known: Self.knownKeys)
        self.init(from: l.double("from") ?? 10, to: l.double("to") ?? 0, format: l.string("format") ?? Self.defaultFormat)
        extra = l.extra()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        for (k, v) in extra { try c.encode(v, forKey: AnyKey(k)) }
        try c.encode(from, forKey: AnyKey("from"))
        try c.encode(to, forKey: AnyKey("to"))
        try c.encode(format, forKey: AnyKey("format"))
    }

    /// クリップの頭からの秒 `rel` のときの数(`duration` で `from` → `to` へ直線)。範囲の外は端に留める。
    public func value(at rel: Double, duration: Double) -> Double {
        guard duration > 0 else { return from }
        let p = min(max(rel / duration, 0), 1)
        return from + (to - from) * p
    }

    /// 表示する文字。減る向きは切り上げ(残り 0.5 秒は 00:01)、増える向きは切り捨て。
    public func text(at rel: Double, duration: Double) -> String {
        let v = value(at: rel, duration: duration)
        let n = from >= to ? Int(ceil(v - 1e-9)) : Int(floor(v + 1e-9))
        let secs = max(0, n)
        switch format {
        case "ss": return String(secs)
        default: return String(format: "%02d:%02d", secs / 60, secs % 60)
        }
    }
}

public extension Clip {
    /// 文字クリップに出す文字。カウントダウンが無ければ `text` そのもの。あれば `text` の後ろに数を続ける。
    func displayText(at t: Double) -> String {
        guard let counter else { return text ?? "" }
        return (text ?? "") + counter.text(at: t - start, duration: duration)
    }
}

/// カウントダウンの編集(インスペクタ・メニュー)。文字クリップだけが対象。何も変わらないときは false(何もしない)。
public enum CounterEditing {
    /// 文字クリップのカウントダウンを置く(nil で外す)。値は `TextCounter` の既定値に丸めてから書く。
    @discardableResult
    public static func set(_ c: inout Clip, to counter: TextCounter?) -> Bool {
        guard c.type == .text else { return false }
        let new = counter.map { TextCounter(from: $0.from, to: $0.to, format: $0.format) }
        guard new != c.counter else { return false }
        c.counter = new
        return true
    }

    /// 付いているカウントダウンの項目を書き換える。付いていないとき・変わらないときは false。
    @discardableResult
    public static func update(_ c: inout Clip, _ change: (inout TextCounter) -> Void) -> Bool {
        guard c.type == .text, var k = c.counter else { return false }
        change(&k)
        let n = TextCounter(from: k.from, to: k.to, format: k.format)
        guard n != c.counter else { return false }
        c.counter = n
        return true
    }
}
