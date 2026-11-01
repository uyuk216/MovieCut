import Foundation

/// 選んだクリップを 1 コマ単位で動かす(クリップ ▸ 1 コマ前へ / 後ろへ)。画面にも依存しない純粋な計算。
/// 移動は `ClipEditing.moveMany` と同じ規則: ロックされたレイヤーのクリップは動かさず、頭は 0 で止まり、重なりは禁止しない。
public enum ClipNudge {
    /// 1 コマの長さ(秒)。fps が不正なら 60 とみなす。
    public static func frameSeconds(fps: Double) -> Double { fps.isFinite && fps > 0 ? 1 / fps : 1.0 / 60 }

    /// 選んだクリップを `frames` コマ動かす(負 = 前へ)。何も変わらないときは nil(Undo に載せない)。
    public static func nudge(in project: Project, clipIds: Set<String>, frames: Int) -> Project? {
        guard frames != 0 else { return nil }
        let ids = LayerEditing.editableIds(clipIds, in: project)
        guard let primary = ids.sorted().first else { return nil }
        let dt = Double(frames) * frameSeconds(fps: project.fps)
        let r = ClipEditing.moveMany(in: project, clipIds: ids, primaryId: primary, deltaT: dt, targetTrackIndex: nil,
                                           playhead: 0, pps: 1, snapEnabled: false)
        return r.project == project ? nil : r.project
    }
}
