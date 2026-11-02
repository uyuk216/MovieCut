import Foundation

// MARK: - 選択クリップの位置合わせ(再生ヘッドに揃える・つなげて並べる)

/// 選んだクリップの頭の位置を揃える純粋関数。どちらも `nil` を返したら変更なし(履歴に載せない)。
/// ロックされたレイヤーのクリップは動かさない(`LayerEditing.editableIds`)。
/// レイヤーは変えない。重なりは禁止しない(ドラッグ移動と同じ方針)。
public enum TimelineAlignment {
    /// 選択の中で一番手前(開始が最も早い)のクリップを再生ヘッドに揃え、残りは同じ量だけずらす(相対位置を保つ)。
    public static func alignToPlayhead(in project: Project, clipIds: Set<String>, playhead: Double) -> Project? {
        let ids = LayerEditing.editableIds(clipIds, in: project)
        let starts = project.allClips.filter { ids.contains($0.id) }.map(\.start)
        guard let first = starts.min(), playhead.isFinite else { return nil }
        let delta = max(0, playhead) - first
        guard abs(delta) > 1e-9 else { return nil }
        return rewritten(project, ids: ids) { _, start in start + delta }
    }

    /// 選んだクリップを、開始時刻順(同時刻は レイヤー順・レイヤー内の順)に、一番手前の開始から隙間なく並べ直す。
    /// 2 つ未満なら nil(並べるものがない)。
    public static func concatenate(in project: Project, clipIds: Set<String>) -> Project? {
        let ids = LayerEditing.editableIds(clipIds, in: project)
        var order: [(id: String, start: Double, duration: Double, track: Int, index: Int)] = []
        for (ti, tr) in project.tracks.enumerated() {
            for (ci, c) in tr.clips.enumerated() where ids.contains(c.id) {
                order.append((c.id, c.start, c.duration, ti, ci))
            }
        }
        guard order.count >= 2 else { return nil }
        order.sort { a, b in
            if a.start != b.start { return a.start < b.start }
            if a.track != b.track { return a.track < b.track }
            return a.index < b.index
        }
        var cursor = order[0].start
        var newStart: [String: Double] = [:]
        for e in order {
            newStart[e.id] = cursor
            cursor += e.duration
        }
        return rewritten(project, ids: ids) { id, _ in newStart[id] }
    }

    /// 対象クリップの頭を書き換える。`newStart(id, 今の頭)` が nil を返したものは動かさない。変化がなければ nil。
    private static func rewritten(_ project: Project, ids: Set<String>, newStart: (String, Double) -> Double?) -> Project? {
        var p = project
        var changed = false
        for ti in p.tracks.indices {
            for ci in p.tracks[ti].clips.indices where ids.contains(p.tracks[ti].clips[ci].id) {
                let c = p.tracks[ti].clips[ci]
                guard let s = newStart(c.id, c.start), s != c.start else { continue }
                p.tracks[ti].clips[ci].start = s
                changed = true
            }
        }
        return changed ? p : nil
    }
}
