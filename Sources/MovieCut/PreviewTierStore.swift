import Foundation
import MovieCutCore

/// プレビュー画質の上書き(表示 ▸ プレビュー画質)。`auto` は作業メモリの予算から決める。
enum PreviewTierOverride: String, CaseIterable, Equatable {
    case auto, full, reduced, minimal

    var title: String {
        switch self {
        case .auto: return "自動"
        case .full: return "フル"
        case .reduced: return "中間"
        case .minimal: return "低メモリ"
        }
    }
}

/// プレビュー画質の設定(アプリ全体。UserDefaults。プロジェクトファイルには入れない)。
/// 静かな検証(MC_DEBUG_*)では UserDefaults に書かない。PreviewBackgroundStore と同じ流儀。
enum PreviewTierStore {
    static let didChange = Notification.Name("MovieCut.previewTierDidChange")
    static let defaultsKey = "previewTierOverride"
    /// 静かな検証用のメモリ上の値(nil なら UserDefaults を見る)。
    nonisolated(unsafe) private static var memory: PreviewTierOverride?

    static var current: PreviewTierOverride {
        if let memory { return memory }
        return DataLocations.current.defaults.string(forKey: defaultsKey).flatMap { PreviewTierOverride(rawValue: $0) } ?? .auto
    }

    static func set(_ o: PreviewTierOverride, defaults: UserDefaults? = DataLocations.current.defaults) {
        if DebugHooks.isQuiet { memory = o } else { defaults?.set(o.rawValue, forKey: defaultsKey) }
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// 実効階級。上書きが auto なら予算から決め、それ以外は上書きどおり。
    static func effectiveTier(override: PreviewTierOverride = current, budget: CacheBudgetManager = AppServices.cacheBudget) -> PreviewTier {
        switch override {
        case .auto: return PreviewTier.tier(for: budget)
        case .full: return .full
        case .reduced: return .reduced
        case .minimal: return .minimal
        }
    }
}
