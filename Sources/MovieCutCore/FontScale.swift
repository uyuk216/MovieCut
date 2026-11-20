import Foundation

/// 素材編集パネルなどの文字サイズの段(設定で選ぶ)。見出し pt／本文 pt を直接持つ。
/// 既定段は見出し×1.31・本文×1.17 の混成で単一倍率では表せないため、pt 直指定。
public enum FontScaleStep: Int, CaseIterable, Sendable {
    case small = 0
    case mediumSmall = 1
    case standard = 2
    case large = 3
    case extraLarge = 4

    public static let `default`: FontScaleStep = .standard

    /// 見出しの pt。
    public var headingSize: CGFloat {
        switch self {
        case .small: return 13
        case .mediumSmall: return 15
        case .standard: return 17
        case .large: return 18
        case .extraLarge: return 20
        }
    }

    /// 本文(ラベル・数値)の pt。
    public var bodySize: CGFloat {
        switch self {
        case .small: return 12
        case .mediumSmall: return 13
        case .standard: return 14
        case .large: return 16
        case .extraLarge: return 18
        }
    }

    /// 本文系の基準サイズ(現行 12pt 基準)を、この段へ換算する。
    public func bodyScaled(base: CGFloat) -> CGFloat { base * bodySize / 12 }
    /// 見出し系の基準サイズ(現行 13pt 基準)を、この段へ換算する。
    public func headingScaled(base: CGFloat) -> CGFloat { base * headingSize / 13 }
}
