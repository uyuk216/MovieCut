import Foundation
import CoreGraphics

// MARK: - プレビュー上で重なったクリップを選ぶ(⌥ クリックで巡回)
//
// 画面の同じ場所に複数のクリップが重なっているとき、見えている手前のクリップだけでなく、その奥のクリップも選べるようにする。
// 当たり判定は、プレビューの選択枠(`TransformBox`)と同じ枠(回転・拡大・切り抜きを反映した四角形)の内側。
// 対象は枠を持つ種類(画像・動画・文字・複合クリップ)で、再生位置にあり、表示中のレイヤーにあり、不透明度が 0 でないもの。
// 並びは手前から奥(描画は配列の後ろほど手前なので、その逆順)。選択はプロジェクトを変えない(Undo に載らない)。
public enum PreviewPicking {
    /// 枠で選べる種類。
    public static func isPickable(_ type: ClipType) -> Bool {
        type == .image || type == .video || type == .text || type == .compound
    }

    /// 時刻 `t`、キャンバスの画素 `point`(左上原点)に重なるクリップの id(手前から奥)。
    public static func hits(in project: Project, at point: CGPoint, time t: Double, assets: RenderAssets) -> [String] {
        guard point.x.isFinite, point.y.isFinite, project.width > 0, project.height > 0 else { return [] }
        let renderer = Renderer(project: project, assets: assets)
        let canvas = CGSize(width: project.width, height: project.height)
        var out: [String] = []
        for id in stack(in: project, at: t).reversed() {       // 奥から手前の並びを、手前から奥へ
            guard let c = ClipEditing.locate(id, in: project).map({ project.tracks[$0.track].clips[$0.index] }),
                  isPickable(c.type) else { continue }
            let rel = t - c.start
            guard Animation.value(of: "opacity", in: c, at: rel) > 0.001,
                  let size = renderer.objectSize(of: c, at: t) else { continue }
            let box = TransformBox.make(clip: c, objectSize: size, at: rel, canvas: canvas)
            switch box.hitTest(point, radius: 0) {
            case .body, .corner: out.append(id)
            case .rotation, .none: break
            }
        }
        // 上のループは reversed で回しているので、out は手前から奥の順
        return out
    }

    /// 再生位置に見えているクリップ(枠を持たないものも含む)の id を、奥から手前の順に。メニューの巡回(座標なし)用。
    /// 調整レイヤー・ぼかし範囲・音だけのクリップ・ボイスは含めない(選んでも画面上で区別できないため)。
    public static func stack(in project: Project, at t: Double) -> [String] {
        project.tracks.filter { !$0.isHidden }.flatMap { tr in
            tr.clips.filter {
                $0.duration > 0 && t >= $0.start - ClipEditing.timeEpsilon && t < $0.start + $0.duration - ClipEditing.timeEpsilon
                    && ($0.type == .image || $0.type == .video || $0.type == .text || $0.type == .compound || $0.type == .shape || $0.type == .visualizer)
            }.map(\.id)
        }
    }

    /// 巡回: `current` の次(最後なら先頭へ)。`current` が候補に無ければ先頭(= いちばん手前 / 並びの先頭)。候補が無ければ nil。
    public static func next(after current: String?, in ids: [String]) -> String? {
        guard !ids.isEmpty else { return nil }
        guard let c = current, let i = ids.firstIndex(of: c) else { return ids[0] }
        return ids[(i + 1) % ids.count]
    }
}
