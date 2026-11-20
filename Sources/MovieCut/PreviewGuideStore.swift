import Foundation
import MovieCutCore

/// プレビューのガイド線の設定(アプリ全体。UserDefaults。プロジェクトにも書き出しにも入らない)。
/// 静かな検証(MC_DEBUG_*)では UserDefaults に書かない。
enum PreviewGuideStore {
    static let didChange = Notification.Name("MovieCut.previewGuidesDidChange")
    /// 静かな検証用のメモリ上の値(nil なら UserDefaults を見る)。
    nonisolated(unsafe) private static var memory: Set<PreviewGuide>?
    /// 表示フラグ(マスター)。保存が無ければ ON。種類集合とは別のキー・別のメモリ。
    static let visibleDefaultsKey = "previewGuidesVisible.v1"
    nonisolated(unsafe) private static var visibleMemory: Bool?
    // 判断: 表示フラグと種類集合は直交する(表示がマスター。種類を選んでも表示は変わらず、表示を切り替えても種類は変わらない)。

    static var current: Set<PreviewGuide> {
        if let memory { return memory }
        return PreviewGuide.resolve(DataLocations.current.defaults.stringArray(forKey: PreviewGuide.defaultsKey))
    }

    static var isVisible: Bool {
        if let visibleMemory { return visibleMemory }
        let d = DataLocations.current.defaults
        guard d.object(forKey: visibleDefaultsKey) != nil else { return true }
        return d.bool(forKey: visibleDefaultsKey)
    }

    static func setVisible(_ v: Bool, defaults: UserDefaults? = DataLocations.current.defaults) {
        if DebugHooks.isQuiet { visibleMemory = v } else { defaults?.set(v, forKey: visibleDefaultsKey) }
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// 表示を切り替える(表示 ▸ ガイド線を表示)。種類集合は変えない。
    static func toggleVisibility(defaults: UserDefaults? = DataLocations.current.defaults) {
        setVisible(!isVisible, defaults: defaults)
    }

    /// 1 つ切り替える(表示 ▸ ガイド線 ▸ 項目)。グリッド系(2×2・3×3・4×4)は排他で、Core の `PreviewGuide.toggled` に従う。
    static func toggle(_ g: PreviewGuide, defaults: UserDefaults? = DataLocations.current.defaults) {
        let s = PreviewGuide.toggled(current, g)
        if DebugHooks.isQuiet { memory = s } else { defaults?.set(PreviewGuide.encode(s), forKey: PreviewGuide.defaultsKey) }
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}
