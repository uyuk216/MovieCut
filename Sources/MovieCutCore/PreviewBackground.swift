import Foundation

/// プレビューの背後の色(アプリ全体の見た目の設定。プロジェクトにも書き出しにも関係しない)。
/// 市松模様は使わず、必ずべた塗り。
public enum PreviewBackground: String, CaseIterable, Equatable {
    case darkGray, black, white, midGray, green, blue

    public static let `default`: PreviewBackground = .darkGray
    /// UserDefaults のキー。
    public static let defaultsKey = "previewBackground.v1"

    public var title: String {
        switch self {
        case .darkGray: return "暗い灰色"
        case .black: return "黒"
        case .white: return "白"
        case .midGray: return "中間グレー"
        case .green: return "緑(クロマキー)"
        case .blue: return "青"
        }
    }

    /// #RRGGBB。
    public var hex: String {
        switch self {
        case .darkGray: return "#1E1E1E"
        case .black: return "#000000"
        case .white: return "#FFFFFF"
        case .midGray: return "#808080"
        case .green: return "#00B140"
        case .blue: return "#0047BB"
        }
    }

    /// 保存した値から復元する。無い・壊れている値は既定(暗い灰色)。
    public static func resolve(_ stored: String?) -> PreviewBackground {
        stored.flatMap { PreviewBackground(rawValue: $0) } ?? .default
    }
}
