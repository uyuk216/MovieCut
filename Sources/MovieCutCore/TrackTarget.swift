import Foundation

/// トラックターゲット: 新しく足すクリップ(素材・テキスト・字幕)の行き先として印を付けたレイヤー。1 つだけ。
/// 印は `Project.targetTrackId`(設定したときだけファイルに書く)。印のレイヤーがロックされている・その時間が埋まっている・無いときは、
/// 今までどおりの置き場所を使う(重ねない・ロックを破らない)。
public enum TrackTarget {
    /// 印のレイヤーの番号。印が無い・レイヤーが消えているときは nil。
    public static func index(in project: Project) -> Int? {
        guard let id = project.targetTrackId else { return nil }
        return project.tracks.firstIndex { $0.id == id }
    }

    /// 印を付ける / 外す。すでにそうなら nil(Undo に載せない)。範囲外の番号は nil。
    public static func set(in project: Project, index: Int, on: Bool) -> Project? {
        guard project.tracks.indices.contains(index) else { return nil }
        var p = project
        let id = p.tracks[index].id
        if on {
            guard p.targetTrackId != id else { return nil }
            p.targetTrackId = id
        } else {
            guard p.targetTrackId == id else { return nil }
            p.targetTrackId = nil
        }
        return p
    }

    /// 印の付け替え(付いていれば外し、無ければ付ける。ほかのレイヤーに付いていれば移す)。
    public static func toggle(in project: Project, index: Int) -> Project? {
        guard project.tracks.indices.contains(index) else { return nil }
        return set(in: project, index: index, on: project.targetTrackId != project.tracks[index].id)
    }

    /// 印のレイヤーが、[start, start+duration) に置けるか(ロックされていず、重なるクリップが無い)。置けるなら番号。
    public static func usableIndex(in project: Project, start: Double, duration: Double) -> Int? {
        guard let i = index(in: project), !project.tracks[i].isLocked else { return nil }
        let end = start + duration
        let free = project.tracks[i].clips.allSatisfy { c in
            c.start >= end - ClipEditing.timeEpsilon || c.start + c.duration <= start + ClipEditing.timeEpsilon
        }
        return free ? i : nil
    }
}
