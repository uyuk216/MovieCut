import Foundation

/// リップルトリム(画面にも Undo にも依存しない純粋な計算)。
/// クリップの頭または尻をトリムし、同じレイヤー(設定によってはすべてのレイヤー)の後ろのクリップを、長さが変わった分だけ前後へずらす。
/// - 頭のトリム: クリップの頭の位置は動かさず、素材の使う区間と長さだけを変える(NLE のリップルトリムと同じ)。後ろのクリップは長さの変化分だけずれる。
/// - 尻のトリム: 長さを変え、後ろのクリップを同じだけずらす。
/// ロックされたクリップ・レイヤーが 1 つでも関わるなら全体を断る。新しい重なりを作る編集も断る。何も変わらないときは nil(Undo に載せない)。
public enum ClipRippleTrim {
    public enum Edge: Equatable { case head, tail }

    /// 頭のトリムの内部計算で、0 秒の下限に当たらないよう一時的に頭の位置へ足す量。
    private static let headroom = 1_000_000.0

    /// 後ろのクリップとみなす境目の許容(秒)。
    static let eps = 1e-6

    public static let lockedNotice = "ロックされたレイヤー・クリップは編集できません"

    // MARK: 影響を受けるクリップ

    /// 動かされる後ろのクリップ(トリムするクリップ自身は含まない)の id。同じレイヤー、`allLayers` ならすべてのレイヤー。
    public static func followers(of clipId: String, in project: Project, allLayers: Bool) -> [String] {
        guard let loc = ClipEditing.locate(clipId, in: project) else { return [] }
        let end = project.tracks[loc.track].clips[loc.index].start + project.tracks[loc.track].clips[loc.index].duration
        var ids: [String] = []
        for (ti, tr) in project.tracks.enumerated() where allLayers || ti == loc.track {
            for c in tr.clips where c.id != clipId && c.start >= end - eps { ids.append(c.id) }
        }
        return ids
    }

    /// 関わるクリップ(トリムするクリップと後ろのクリップ)にロックがあるか。
    public static func touchesLocked(_ clipId: String, in project: Project, allLayers: Bool) -> Bool {
        ([clipId] + followers(of: clipId, in: project, allLayers: allLayers)).contains { LayerEditing.isLockedClip($0, in: project) }
    }

    /// メニュー用: 再生位置へのリップルトリムが使えない理由(使えるなら nil)。
    public static func blockedReason(in project: Project, clipId: String?, edge: Edge, playhead: Double, allLayers: Bool) -> String? {
        guard let clipId, let loc = ClipEditing.locate(clipId, in: project) else { return "クリップを 1 つ選んでください" }
        let c = project.tracks[loc.track].clips[loc.index]
        guard playhead > c.start + ClipEditing.minDuration - 1e-9, playhead < c.start + c.duration - ClipEditing.minDuration + 1e-9 else {
            return "再生位置が選んだクリップの途中にありません"
        }
        if touchesLocked(clipId, in: project, allLayers: allLayers) { return lockedNotice }
        return nil
    }

    // MARK: ドラッグ / 量を指定

    /// 頭または尻を `deltaT` 秒(ドラッグの動き)だけトリムして、後ろを詰める / 空ける。
    /// 頭は「頭の端を動かす」向きで、正 = 後ろへ(縮める)、負 = 前へ(素材が残っていれば延ばす)。尻は正 = 延ばす、負 = 縮める。
    /// 変わらない・ロックに触れる・新しい重なりができるときは nil。
    public static func trim(in project: Project, clipId: String, edge: Edge, deltaT: Double, allLayers: Bool,
                            playhead: Double, pps: Double, snapEnabled: Bool) -> ClipEditing.Result? {
        guard deltaT.isFinite, let loc = ClipEditing.locate(clipId, in: project),
              !touchesLocked(clipId, in: project, allLayers: allLayers) else { return nil }
        let c0 = project.tracks[loc.track].clips[loc.index]
        let oldStart = c0.start, oldDur = c0.duration
        var guides: [Double] = []
        var p = project
        let shift: Double          // 後ろのクリップをずらす量
        switch edge {
        case .tail:
            let r = ClipEditing.trimRight(in: project, clipId: clipId, deltaT: deltaT, playhead: playhead, pps: pps, snapEnabled: snapEnabled)
            guard let l = ClipEditing.locate(clipId, in: r.project) else { return nil }
            let c1 = r.project.tracks[l.track].clips[l.index]
            shift = c1.duration - oldDur
            p.tracks[loc.track].clips[loc.index] = c1
            guides = r.guides
        case .head:
            // 頭の端がある時刻(動かす先)を吸着させてから、トリムの計算(素材の区間・最短の長さ・速度)に任せる。
            // 頭の位置は動かさないので、計算の間だけ 0 秒の下限に当たらない所へ置く。
            let raw = oldStart + deltaT
            let sp = ClipEditing.snapPoint(raw, excluding: clipId, project: project, playhead: playhead, pps: pps, enabled: snapEnabled)
            var tmp = project
            tmp.tracks[loc.track].clips[loc.index].start = oldStart + headroom
            let r = ClipEditing.trimLeft(in: tmp, clipId: clipId, deltaT: (sp ?? raw) - oldStart, playhead: 0, pps: 1, snapEnabled: false)
            guard let l = ClipEditing.locate(clipId, in: r.project) else { return nil }
            var c1 = r.project.tracks[l.track].clips[l.index]
            let moved = ((c1.start - (oldStart + headroom)) * 1e9).rounded() / 1e9      // 頭の端が実際に動いた量
            c1.start = oldStart
            shift = -moved
            p.tracks[loc.track].clips[loc.index] = c1
            if let sp, abs(sp - (oldStart + moved)) < 1e-9 { guides = [sp] }
        }
        guard abs(shift) > 1e-9 else { return nil }
        // 後ろのクリップをずらす
        let follow = Set(followers(of: clipId, in: project, allLayers: allLayers))
        for ti in p.tracks.indices {
            for ci in p.tracks[ti].clips.indices where follow.contains(p.tracks[ti].clips[ci].id) {
                p.tracks[ti].clips[ci].start = max(0, p.tracks[ti].clips[ci].start + shift)
            }
        }
        // 新しい重なりを作らない(元からの重なりは数えない)
        let touched = allLayers ? Array(p.tracks.indices) : [loc.track]
        for ti in touched where overlapCount(p.tracks[ti].clips) > overlapCount(project.tracks[ti].clips) { return nil }
        guard p != project else { return nil }
        return ClipEditing.Result(project: p, guides: guides)
    }

    /// 再生位置まで頭 / 尻をトリムする(再生位置がクリップの途中にあるときだけ)。
    public static func trimToPlayhead(in project: Project, clipId: String, edge: Edge, playhead: Double, allLayers: Bool) -> Project? {
        guard blockedReason(in: project, clipId: clipId, edge: edge, playhead: playhead, allLayers: allLayers) == nil,
              let loc = ClipEditing.locate(clipId, in: project) else { return nil }
        let c = project.tracks[loc.track].clips[loc.index]
        let d = edge == .head ? playhead - c.start : playhead - (c.start + c.duration)
        return trim(in: project, clipId: clipId, edge: edge, deltaT: d, allLayers: allLayers, playhead: playhead, pps: 1, snapEnabled: false)?.project
    }

    /// 1 つのレイヤーの中で、時間が重なっているクリップの組の数。
    static func overlapCount(_ clips: [Clip]) -> Int {
        var n = 0
        for i in clips.indices {
            for j in clips.indices where j > i {
                let a = clips[i], b = clips[j]
                if a.start < b.start + b.duration - eps && b.start < a.start + a.duration - eps { n += 1 }
            }
        }
        return n
    }
}
