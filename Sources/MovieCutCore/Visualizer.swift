import Foundation

/// 音声ビジュアライザ(クリップの種類 visualizer)の見た目。未設定の項目は既定値(棒・白・32 本)。
/// クリップに `visualizer` ごと無いときは、全部既定値。ファイルには設定した項目だけ書く。
public struct Visualizer: Codable, Equatable, Sendable {
    public static let styles = ["bars", "wave"]
    public static let defaultStyle = "bars"
    public static let defaultColor = "#ffffff"
    public static let defaultCount = 32
    public static let countRange: ClosedRange<Int> = 4...128

    /// "bars"(棒)/ "wave"(上下対称の波)。未知の値は棒として扱う。
    public var style: String?
    /// 色(#rrggbb)。
    public var color: String?
    /// 棒の本数(波のときは点の数)。4〜128。
    public var count: Int?

    /// 知らないキー(新しい版が書いた項目)。そのまま書き戻す。
    public var extra: [String: JSONValue] = [:]
    static let knownKeys: Set<String> = ["style", "color", "count"]

    public init(style: String? = nil, color: String? = nil, count: Int? = nil) {
        self.style = style; self.color = color; self.count = count
    }

    public init(from decoder: Decoder) throws {
        let l = Lenient(c: try decoder.container(keyedBy: AnyKey.self), known: Self.knownKeys)
        style = l.string("style")
        color = l.string("color")
        count = l.int("count")
        extra = l.extra()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        for (k, v) in extra { try c.encode(v, forKey: AnyKey(k)) }
        try c.encodeIfPresent(style, forKey: AnyKey("style"))
        try c.encodeIfPresent(color, forKey: AnyKey("color"))
        try c.encodeIfPresent(count, forKey: AnyKey("count"))
    }

    public var styleOrDefault: String { let s = style ?? Self.defaultStyle; return Self.styles.contains(s) ? s : Self.defaultStyle }
    public var colorOrDefault: String { color ?? Self.defaultColor }
    public var countOrDefault: Int { min(max(count ?? Self.defaultCount, Self.countRange.lowerBound), Self.countRange.upperBound) }
}

extension Clip {
    /// ビジュアライザの見た目(未設定は既定)。
    public var visualizerOrDefault: Visualizer { visualizer ?? Visualizer() }
}
