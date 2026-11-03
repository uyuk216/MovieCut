import Foundation

/// 連続する同じ素材の分割点を統合する(候補 34)。`ClipEditing.split` の逆。
/// 統合できるのは、同じレイヤーで隣り合い(すき間・重なりが無い)、同じ素材の続きを使う、動画・音声・画像のクリップの組で、
/// 「統合したクリップを、つなぎ目で分割し直すと、元の 2 つに戻る」ものだけ。つまり、つなぎ目以外の設定(エフェクト・音量・位置など)が同じで、
/// つなぎ目にトランジション・フェードが無く、素材の時刻が途切れていないこと。条件に合わないものは、黙って残す。
/// ロックされたレイヤー・クリップは変えない。
public enum ClipMerge {
    public struct Result: Equatable {
        public var project: Project
        /// 取り除いたクリップの数(統合した分割点の数)。
        public var merged: Int
        /// 統合の結果として残ったクリップの id(先頭側の id を引き継ぐ)。
        public var keptIds: [String]
    }

    static let timeTolerance = 1e-5

    public static func supports(_ c: Clip) -> Bool {
        (c.type == .video || c.type == .audio || c.type == .image) && c.src != nil && !c.isFreeze && c.speedRamp == nil
    }

    /// 2 つのクリップ(時間順に a → b)を 1 つにまとめた結果。統合できなければ nil。id は a のものを残す。
    public static func merged(_ a: Clip, _ b: Clip) -> Clip? {
        guard supports(a), supports(b), a.type == b.type, a.src == b.src else { return nil }
        let join = a.start + a.duration
        guard abs(join - b.start) < timeTolerance, a.duration > 0, b.duration > 0 else { return nil }
        var m = a
        m.duration = a.duration + b.duration
        m.transitionOut = b.transitionOut
        m.fadeOut = b.fadeOut
        if ClipEditing.hasSourceTimeline(a.type) {
            guard abs(a.effectiveSpeed - b.effectiveSpeed) < 1e-9, a.effectiveReverse == b.effectiveReverse else { return nil }
            let sp = a.effectiveSpeed
            if a.effectiveReverse {
                guard abs(a.offset - (b.offset + b.duration * sp)) < 1e-4 else { return nil }
                m.offset = b.offset
            } else {
                guard abs(b.offset - (a.offset + a.duration * sp)) < 1e-4 else { return nil }
            }
        }
        guard a.keyframes.keys == b.keyframes.keys else { return nil }
        // キーフレームが無ければそのまま検証する。あれば、まず全部のキーを残して(つなぎ目のキーは 1 つにまとめる)検証し、
        // 項目ごとに、つなぎ目のキーを落とせるか(落としても分割し直すと元に戻るか)を試す。
        if a.keyframes.isEmpty { return verified(m, a, b, at: join) ? m : nil }
        var kept: [String: [Keyframe]] = [:]
        var dropped: [String: [Keyframe]] = [:]
        for (key, la) in a.keyframes {
            let rb = (b.keyframes[key] ?? []).map { Keyframe(t: $0.t + a.duration, v: $0.v, ease: $0.ease) }
            kept[key] = Animation.normalized(la + rb)
            dropped[key] = la.filter { abs($0.t - a.duration) >= 1e-9 } + rb.filter { abs($0.t - a.duration) >= 1e-9 }
        }
        var cand = m
        cand.keyframes = kept
        guard verified(cand, a, b, at: join) else { return nil }
        for key in kept.keys.sorted() where kept[key] != dropped[key] {
            var trial = cand
            trial.keyframes[key] = dropped[key]
            if verified(trial, a, b, at: join) { cand = trial }
        }
        return cand
    }

    /// 統合したクリップを `join` で分割し直すと、元の 2 つ(id・時刻・素材の頭のわずかな誤差を除いて)に戻るか。
    private static func verified(_ merged: Clip, _ a: Clip, _ b: Clip, at join: Double) -> Bool {
        guard var (l, r) = ClipEditing.split(merged, at: join) else { return false }
        l.duration = a.duration
        if abs(l.offset - a.offset) < 1e-4 { l.offset = a.offset } else { return false }
        r.id = b.id; r.start = b.start; r.duration = b.duration
        if abs(r.offset - b.offset) < 1e-4 { r.offset = b.offset } else { return false }
        return l == a && r == b
    }

    /// 統合できる分割点があるか(メニューの有効・無効)。
    public static func hasMergeable(in project: Project, scope: Set<String>? = nil) -> Bool {
        for tr in project.tracks where !tr.isLocked {
            let order = ordered(tr)
            for k in 0..<max(0, order.count - 1) {
                let a = tr.clips[order[k]], b = tr.clips[order[k + 1]]
                if let s = scope, !s.contains(a.id) && !s.contains(b.id) { continue }
                if a.isClipLocked || b.isClipLocked { continue }
                if merged(a, b) != nil { return true }
            }
        }
        return false
    }

    /// 時刻順のクリップの添字。
    private static func ordered(_ tr: Track) -> [Int] {
        tr.clips.indices.sorted { (tr.clips[$0].start, $0) < (tr.clips[$1].start, $1) }
    }

    /// 分割点を一括で統合する。`scope` が nil なら全部、あればそのクリップのどちらか一方でも含む組だけ。
    /// 3 つ以上の連なりは 1 つにまとまる。統合するものが無ければ nil。
    public static func mergeAll(in project: Project, scope: Set<String>? = nil) -> Result? {
        var p = project
        var count = 0
        var kept: [String] = []
        for ti in p.tracks.indices where !p.tracks[ti].isLocked {
            var changed = true
            while changed {
                changed = false
                let order = ordered(p.tracks[ti])
                for k in 0..<max(0, order.count - 1) {
                    let ai = order[k], bi = order[k + 1]
                    let a = p.tracks[ti].clips[ai], b = p.tracks[ti].clips[bi]
                    if let s = scope, !s.contains(a.id) && !s.contains(b.id) { continue }
                    if a.isClipLocked || b.isClipLocked { continue }
                    guard let m = merged(a, b) else { continue }
                    p.tracks[ti].clips[ai] = m
                    p.tracks[ti].clips.remove(at: bi)
                    count += 1
                    changed = true
                    break
                }
            }
        }
        guard count > 0 else { return nil }
        // 残ったクリップのうち、統合に関わったもの(元より長くなったもの)
        for tr in p.tracks {
            for c in tr.clips {
                guard let old = project.tracks.flatMap(\.clips).first(where: { $0.id == c.id }), old.duration != c.duration else { continue }
                kept.append(c.id)
            }
        }
        return Result(project: p, merged: count, keptIds: kept)
    }
}
