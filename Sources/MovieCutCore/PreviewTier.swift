import Foundation

/// プレビューの階級(予算階級から決まる描画の軽さ)。
///
/// 対象は**動画レイヤーのみ**: 画像・文字・図形などの静的レイヤーは
/// プレビューでも常にフル解像度で描く前提で、この階級は適用しない。
/// 描画パイプラインへの本接続はこの型の範囲外(判定ロジックのみ)。
public enum PreviewTier: String, Equatable, Sendable, CaseIterable {
    /// フル解像度・フル fps。
    case full
    /// 解像度 1/4(scale 0.25)・fps そのまま。
    case reduced
    /// 解像度 1/16(scale 0.0625)・fps 半分。
    case minimal

    /// 描画スケール(幅・高さそれぞれに掛ける)。
    public var resolutionScale: Double {
        switch self {
        case .full: return 1.0
        case .reduced: return 0.25
        case .minimal: return 0.0625
        }
    }

    /// fps への倍率。
    public var fpsScale: Double {
        switch self {
        case .full, .reduced: return 1.0
        case .minimal: return 0.5
        }
    }

    /// この階級が適用されるのは動画レイヤーのみであることを型で表すための判定。
    public func applies(to clipType: ClipType) -> Bool {
        clipType == .video
    }

    /// 動画レイヤー以外には常に `.full` 相当として扱うための便利判定。
    public func effectiveTier(for clipType: ClipType) -> PreviewTier {
        applies(to: clipType) ? self : .full
    }

    /// 実効 fps(動画レイヤー用)。
    public func effectiveFPS(base: Double) -> Double { base * fpsScale }

    /// 実効描画サイズ(動画レイヤー用)。最小 1 ピクセルを保証する。
    public func effectiveSize(width: Int, height: Int) -> (width: Int, height: Int) {
        (max(1, Int((Double(width) * resolutionScale).rounded())),
         max(1, Int((Double(height) * resolutionScale).rounded())))
    }

    // MARK: - 判定

    /// 予算(上限バイト数)から階級を決める純粋関数。
    /// - 上限なし → `.full`
    /// - 上限 2GB 以上 → `.reduced`
    /// - 上限 2GB 未満 → `.minimal`
    public static func tier(forLimitBytes limit: Int64?) -> PreviewTier {
        guard let limit else { return .full }
        return limit >= 2 * MemoryBudget.gib ? .reduced : .minimal
    }

    /// 総 RAM とプラットフォームから直接決める。
    public static func tier(totalRAMBytes: Int64, platform: MemoryBudgetPlatform = .mac) -> PreviewTier {
        tier(forLimitBytes: MemoryBudget.limitBytes(totalRAMBytes: totalRAMBytes, platform: platform))
    }

    /// CacheBudgetManager の上限から決める。
    public static func tier(for manager: CacheBudgetManager) -> PreviewTier {
        tier(forLimitBytes: manager.limitBytes)
    }
}
