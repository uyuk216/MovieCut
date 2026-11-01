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

    public init(style: String? = nil, color: String? = nil, count: Int? = nil) {
        self.style = style; self.color = color; self.count = count
    }

    public var styleOrDefault: String { let s = style ?? Self.defaultStyle; return Self.styles.contains(s) ? s : Self.defaultStyle }
    public var colorOrDefault: String { color ?? Self.defaultColor }
    public var countOrDefault: Int { min(max(count ?? Self.defaultCount, Self.countRange.lowerBound), Self.countRange.upperBound) }
}

extension Clip {
    /// ビジュアライザの見た目(未設定は既定)。
    public var visualizerOrDefault: Visualizer { visualizer ?? Visualizer() }
}
