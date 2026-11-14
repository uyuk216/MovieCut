import Foundation
import CoreGraphics

// MARK: - ブレンドモード(合成方法)
//
// クリップを下のレイヤーとどう重ねるか。ファイルには文字列で持ち、無いときは通常(source-over)。
// 描画は Renderer が CGContext のブレンドモードで効かせる(プレビュー・書き出しとも同じ経路)。
// 対応は画像・動画・文字・複合・立ち絵クリップ。調整・ぼかし・図形・音声には効かない。

public enum ClipBlendMode: String, CaseIterable, Equatable, Hashable, Sendable {
    case multiply
    case screen
    case overlay
    case darken
    case lighten
    case colorDodge
    case colorBurn
    case softLight
    case hardLight
    case difference
    case exclusion
    case hue
    case saturation
    case color
    case luminosity
    /// 加算(プラス)
    case plusLighter

    public var cgBlendMode: CGBlendMode {
        switch self {
        case .multiply: return .multiply
        case .screen: return .screen
        case .overlay: return .overlay
        case .darken: return .darken
        case .lighten: return .lighten
        case .colorDodge: return .colorDodge
        case .colorBurn: return .colorBurn
        case .softLight: return .softLight
        case .hardLight: return .hardLight
        case .difference: return .difference
        case .exclusion: return .exclusion
        case .hue: return .hue
        case .saturation: return .saturation
        case .color: return .color
        case .luminosity: return .luminosity
        case .plusLighter: return .plusLighter
        }
    }

    public var label: String {
        switch self {
        case .multiply: return "乗算"
        case .screen: return "スクリーン"
        case .overlay: return "オーバーレイ"
        case .darken: return "比較（暗）"
        case .lighten: return "比較（明）"
        case .colorDodge: return "覆い焼き"
        case .colorBurn: return "焼き込み"
        case .softLight: return "ソフトライト"
        case .hardLight: return "ハードライト"
        case .difference: return "差分"
        case .exclusion: return "除外"
        case .hue: return "色相"
        case .saturation: return "彩度"
        case .color: return "カラー"
        case .luminosity: return "輝度"
        case .plusLighter: return "加算"
        }
    }
}
