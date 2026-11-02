import Foundation

// MARK: - 選択クリップの位置合わせ(再生ヘッドに揃える・つなげて並べる)

/// 選んだクリップの頭の位置を揃える純粋関数。
/// ロックされたレイヤーのクリップは動かさない(`LayerEditing.editableIds`)。レイヤーは変えない。
/// 2026-11-02: 動かした結果、同じレイヤーの「選んでいない」クリップ(または動かしたクリップ同士)と新しく重なるなら
/// 何も変えず `.blocked`(理由の文)を返す。ずらして詰める(リップル)はしない。
public enum TimelineAlignment {
    public enum Outcome: Equatable {
        /// 位置が変わった(その結果)。
        case changed(Project)
        /// 変わらない(履歴に載せない)。
        case unchanged
        /// 重なるので動かさない。画面に出す日本語の理由。
        case blocked(String)
    }

    /// 選択の中で一番手前(開始が最も早い)のクリップを再生ヘッドに揃え、残りは同じ量だけずらす(相対位置を保つ)。
    public static func alignToPlayhead(in project: Project, clipIds: Set<String>, playhead: Double) -> Outcome {
        let ids = LayerEditing.editableIds(clipIds, in: project)
        let starts = project.allClips.filter { ids.contains($0.id) }.map(\.start)
        guard let first = starts.min(), playhead.isFinite else { return .unchanged }
        let delta = max(0, playhead) - first
        guard abs(delta) > 1e-9 else { return .unchanged }
        return checked(rewritten(project, ids: ids) { _, start in start + delta }, original: project, moved: ids)
    }

    /// 選んだクリップを、開始時刻順(同時刻は レイヤー順・レイヤー内の順)に、一番手前の開始から隙間なく並べ直す。
    /// 2 つ未満なら `.unchanged`(並べるものがない)。
    public static func concatenate(in project: Project, clipIds: Set<String>) -> Outcome {
        let ids = LayerEditing.editableIds(clipIds, in: project)
        var order: [(id: String, start: Double, duration: Double, track: Int, index: Int)] = []
        for (ti, tr) in project.tracks.enumerated() {
            for (ci, c) in tr.clips.enumerated() where ids.contains(c.id) {
                order.append((c.id, c.start, c.duration, ti, ci))
            }
        }
        guard order.count >= 2 else { return .unchanged }
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
        return checked(rewritten(project, ids: ids) { id, _ in newStart[id] }, original: project, moved: ids)
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

    /// 結果の重なりを調べる。元には無く、結果で新しく重なり、かつ動かしたクリップが関わるものがあれば `.blocked`。
    private static func checked(_ result: Project?, original: Project, moved: Set<String>) -> Outcome {
        guard let result else { return .unchanged }
        let before = overlapPairs(original)
        let after = overlapPairs(result)
        guard let bad = after.sorted(by: { ($0.a, $0.b) < ($1.a, $1.b) }).first(where: { pair in
            !before.contains(pair) && (moved.contains(pair.a) || moved.contains(pair.b))
        }) else { return .changed(result) }
        let layer = layerName(of: bad.a, in: result) ?? "レイヤー"
        return .blocked("\(layer)の別のクリップと重なるため動かせません。空きのある位置へ移してから、もう一度してください。")
    }

    /// 同じレイヤーで時間が重なるクリップの組(id の組。並びは安定させる)。
    fileprivate static func overlapPairs(_ p: Project) -> Set<OverlapPair> {
        var out = Set<OverlapPair>()
        for tr in p.tracks {
            let cs = tr.clips
            for i in cs.indices {
                for j in cs.indices where j > i {
                    let a = cs[i], b = cs[j]
                    if a.start < b.start + b.duration - 1e-9 && b.start < a.start + a.duration - 1e-9 {
                        out.insert(OverlapPair(a.id, b.id))
                    }
                }
            }
        }
        return out
    }

    private static func layerName(of clipId: String, in p: Project) -> String? {
        p.tracks.first { $0.clips.contains { $0.id == clipId } }.map { "「\($0.name)」" }
    }

    /// 向きを揃えた id の組(a < b)。
    fileprivate struct OverlapPair: Hashable {
        let a: String, b: String
        init(_ x: String, _ y: String) { if x <= y { a = x; b = y } else { a = y; b = x } }
    }
}
