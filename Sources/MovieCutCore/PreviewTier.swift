import Foundation

/// プレビューの階級(予算階級から決まる描画の軽さ)。
///
/// 対象は**動画レイヤーのみ**: 画像・文字・図形などの静的レイヤーは
/// プレビューでも常にフル解像度で描く前提で、この階級は適用しない。
/// 描画パイプラインへの本接続はこの型の範囲外(判定ロジックのみ)。
public enum PreviewTier: String, Equatable, Sendable, CaseIterable {
    /// フル解像度・フル fps。
    case full
    /// 解像度 1/4(面積比。縦横それぞれ 1/2)・fps そのまま。
    case reduced
    /// 解像度 1/16(面積比。縦横それぞれ 1/4)・fps 半分。
    case minimal

    /// 描画スケール(幅・高さそれぞれに掛ける倍率)。仕様の解像度比(1/4・1/16)は面積比なので、縦横の倍率は 1/2・1/4 になる。
    public var resolutionScale: Double {
        switch self {
        case .full: return 1.0
        case .reduced: return 0.5
        case .minimal: return 0.25
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
        (scaledSize(width), scaledSize(height))
    }

    /// 寸法の換算(最小 1)。Int へ変える前に Double の範囲で丸める(巨大な寸法で落ちない)。
    private func scaledSize(_ v: Int) -> Int {
        let d = (Double(v) * resolutionScale).rounded()
        guard d.isFinite, d > 1 else { return 1 }
        return d >= Double(Int.max) ? Int.max : Int(d)
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
