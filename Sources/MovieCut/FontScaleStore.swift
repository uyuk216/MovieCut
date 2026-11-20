import Foundation
import MovieCutCore

/// 文字サイズの段の設定(アプリ全体。UserDefaults)。静かな検証(MC_DEBUG_*)ではメモリだけ。
enum FontScaleStore {
    static let didChange = Notification.Name("MovieCut.fontScaleStepDidChange")
    static let defaultsKey = "fontScaleStep.v1"
    nonisolated(unsafe) private static var memory: FontScaleStep?

    static var current: FontScaleStep {
        if let memory { return memory }
        return resolve(DataLocations.current.defaults)
    }

    /// 保存が無い／壊れているときは既定(標準)。
    static func resolve(_ defaults: UserDefaults) -> FontScaleStep {
        guard defaults.object(forKey: defaultsKey) != nil,
              let s = FontScaleStep(rawValue: defaults.integer(forKey: defaultsKey)) else { return .default }
        return s
    }

    static func set(_ step: FontScaleStep, defaults: UserDefaults? = DataLocations.current.defaults) {
        if DebugHooks.isQuiet { memory = step } else { defaults?.set(step.rawValue, forKey: defaultsKey) }
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// 試験用: メモリ上の値を捨てる。
    static func resetMemory() { memory = nil }
}
