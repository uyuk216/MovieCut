import Foundation
import MovieCutCore

/// プレビューのガイド線の設定(アプリ全体。UserDefaults。プロジェクトにも書き出しにも入らない)。
/// 静かな検証(MC_DEBUG_*)では UserDefaults に書かない。
enum PreviewGuideStore {
    static let didChange = Notification.Name("MovieCut.previewGuidesDidChange")
    /// 静かな検証用のメモリ上の値(nil なら UserDefaults を見る)。
    nonisolated(unsafe) private static var memory: Set<PreviewGuide>?

    static var current: Set<PreviewGuide> {
        if let memory { return memory }
        return PreviewGuide.resolve(DataLocations.current.defaults.stringArray(forKey: PreviewGuide.defaultsKey))
    }

    /// 1 つ切り替える(表示 ▸ ガイド線 ▸ 項目)。グリッド系(2×2・3×3・4×4)は排他で、Core の `PreviewGuide.toggled` に従う。
    static func toggle(_ g: PreviewGuide, defaults: UserDefaults? = DataLocations.current.defaults) {
        let s = PreviewGuide.toggled(current, g)
        if DebugHooks.isQuiet { memory = s } else { defaults?.set(PreviewGuide.encode(s), forKey: PreviewGuide.defaultsKey) }
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}
