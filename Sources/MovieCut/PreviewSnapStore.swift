import Foundation
import MovieCutCore

/// プレビューの直接操作のスナップ(吸着)の設定(アプリ全体。UserDefaults。プロジェクトにも書き出しにも入らない)。
/// 既定は ON(保存が無ければ吸着する)。静かな検証(MC_DEBUG_*)では UserDefaults に書かない。PreviewGuideStore と同じ流儀。
enum PreviewSnapStore {
    static let didChange = Notification.Name("MovieCut.previewSnapDidChange")
    static let defaultsKey = "previewSnap.v1"
    /// 静かな検証用のメモリ上の値(nil なら UserDefaults を見る)。
    nonisolated(unsafe) private static var memory: Bool?

    static var current: Bool {
        if let memory { return memory }
        let d = DataLocations.current.defaults
        guard d.object(forKey: defaultsKey) != nil else { return true }
        return d.bool(forKey: defaultsKey)
    }

    static func set(_ v: Bool, defaults: UserDefaults? = DataLocations.current.defaults) {
        if DebugHooks.isQuiet { memory = v } else { defaults?.set(v, forKey: defaultsKey) }
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// 切り替える(表示 ▸ スナップ)。
    static func toggle(defaults: UserDefaults? = DataLocations.current.defaults) {
        set(!current, defaults: defaults)
    }
}
