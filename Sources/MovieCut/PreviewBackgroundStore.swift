import Foundation
import MovieCutCore

/// プレビューの背景色の設定(アプリ全体。UserDefaults。プロジェクトファイルには入れない)。
/// 静かな検証(MC_DEBUG_*)では UserDefaults に書かない。
enum PreviewBackgroundStore {
    static let didChange = Notification.Name("MovieCut.previewBackgroundDidChange")
    /// 静かな検証用のメモリ上の値(nil なら UserDefaults を見る)。
    nonisolated(unsafe) private static var memory: PreviewBackground?

    static var current: PreviewBackground {
        if let memory { return memory }
        return PreviewBackground.resolve(UserDefaults.standard.string(forKey: PreviewBackground.defaultsKey))
    }

    static func set(_ b: PreviewBackground, defaults: UserDefaults? = .standard) {
        if DebugHooks.isQuiet { memory = b } else { defaults?.set(b.rawValue, forKey: PreviewBackground.defaultsKey) }
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}
