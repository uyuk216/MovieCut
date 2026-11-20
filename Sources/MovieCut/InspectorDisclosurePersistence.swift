import Foundation
import MovieCutCore

/// 音声エフェクト系パネル(AudioFxPanel / AudioFxExtendedPanel / VST3Panel)の開閉の保存。
/// 「ユーザーが明示的に開閉した値だけ」を `mc.disclosure.<id>` に残し、未保存なら nil を返して
/// 呼び出し側の従来の既定判定(forceExpanded か、効いている節だけ開く)を使わせる。
/// 固定値の AppStorage<Bool> に置き換えると「効いている節だけ開く」既定が壊れるため、この形にしている。
enum InspectorDisclosurePersistence {
    static func saved(_ id: String) -> Bool? { InspectorDisclosureStore.standard.saved(id: id) }

    static func save(_ open: Bool, id: String) { InspectorDisclosureStore.standard.set(open, id: id) }

    /// 拡張エフェクトの保存済みの開閉(キーは `AudioFxExtendedPanel` のグループ名)。
    static func savedExtended() -> [String: Bool] {
        var r: [String: Bool] = [:]
        for k in InspectorSectionCatalog.audioFxExtendedKeys {
            if let v = saved("inspector.audioFx.ext.\(k)") { r[k] = v }
        }
        return r
    }
}
