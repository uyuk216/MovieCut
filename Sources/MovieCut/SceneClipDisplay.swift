import Foundation
import MovieCutCore

/// シーンクリップ専用表示の文言(R2-3)。タイムラインのラベルとインスペクタの概要で共用する。
/// シーンクリップは素材パスを持たないので、通常クリップの流儀(素材名)では何も出ない。
/// ここでは参照先シーンの名前と中身の概要を出すことで、通常クリップと見分けられるようにする。
enum SceneClipDisplay {
    /// タイムラインのラベル: 「シーン「名前」」。参照先が無い(壊れた参照)ときは、そのことが分かる文言。
    static func label(for c: Clip, in p: Project) -> String {
        guard c.type == .scene else { return "" }
        guard let sid = c.sceneId, let s = p.scene(withId: sid) else { return "シーン（参照切れ）" }
        return "シーン「\(s.name)」"
    }

    /// インスペクタの概要: レイヤー数・クリップ数・シーン尺・参照箇所数。参照先が無ければ nil。
    static func summary(for c: Clip, in p: Project) -> String? {
        guard c.type == .scene, let sid = c.sceneId, let s = p.scene(withId: sid) else { return nil }
        let clips = s.tracks.reduce(0) { $0 + $1.clips.count }
        let refs = SceneEditing.referenceCount(in: p, sceneId: sid)
        return "レイヤー \(s.tracks.count)・クリップ \(clips)・尺 \(String(format: "%.2f", SceneEditing.duration(of: s))) 秒・参照 \(refs) 箇所"
    }
}
