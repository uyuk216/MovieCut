import Foundation

/// 無音カット: 選んだクリップを無音の範囲で切り分け、無音の部分を取り除く(任意で後ろを詰める)。
extension ClipEditing {
    /// 切る範囲のうち、クリップの中に収まって意味のある長さのものだけを、開始順・重なりなしに整える。
    static func normalizedCuts(_ cuts: [SilenceRange], duration: Double) -> [SilenceRange] {
        var out: [SilenceRange] = []
        for c in cuts.sorted(by: { $0.start < $1.start }) {
            let a = max(0, c.start), b = min(duration, c.end)
            guard b - a > timeEpsilon else { continue }
            if let last = out.last, a <= last.end + timeEpsilon { out[out.count - 1].end = max(last.end, b) }
            else { out.append(SilenceRange(start: a, end: b)) }
        }
        return out
    }

    /// 取り除いたあとに残る、短すぎる断片(最短の長さ未満)は残さない。
    /// - Parameters:
    ///   - cuts: 取り除く範囲(クリップの頭からの秒)
    ///   - ripple: true なら、残した断片を前へ詰め、同じレイヤーの後ろのクリップも取り除いた長さだけ左へ詰める
    /// - Returns: 新しいプロジェクトと、残った断片の id(先頭は元のクリップの id)。切る範囲が無い・全部が無音になる・対象外なら nil。
    public static func removeSilence(in project: Project, clipId: String, cuts rawCuts: [SilenceRange], ripple: Bool) -> (project: Project, clipIds: [String])? {
        guard let loc = locate(clipId, in: project) else { return nil }
        let clip = project.tracks[loc.track].clips[loc.index]
        guard SilenceDetector.supports(clip) else { return nil }
        let cuts = normalizedCuts(rawCuts, duration: clip.duration)
        guard !cuts.isEmpty else { return nil }
        var keeps = SilenceDetector.keepRanges(silent: cuts, duration: clip.duration).filter { $0.length >= minDuration }
        guard !keeps.isEmpty else { return nil }
        keeps.sort { $0.start < $1.start }

        // 断片を作る: 左から順に、残す範囲の頭で切る(split がフェード・キーフレーム・トランジションの振り分けを受け持つ)
        var pieces: [Clip] = []
        var rest = clip
        var consumed = 0.0          // rest の頭の、元のクリップの頭からの秒
        for (i, k) in keeps.enumerated() {
            // 残す範囲の頭まで(無音の頭側)を捨てる
            if k.start > consumed + timeEpsilon {
                guard let (_, right) = split(rest, at: clip.start + k.start) else { return nil }
                rest = right; consumed = k.start
            }
            // 残す範囲の終わりで切る(最後の断片は、終わりまで残るときは切らない)
            if k.end < clip.duration - timeEpsilon, let (left, right) = split(rest, at: clip.start + k.end) {
                var piece = left
                if i > 0 { piece.id = newId() }
                pieces.append(piece)
                rest = right; consumed = k.end
            } else {
                var piece = rest
                if i > 0 { piece.id = newId() }
                pieces.append(piece)
                consumed = clip.duration
            }
        }
        // 先頭の断片が元の id を引き継ぐ(split の左は元の id のまま)
        pieces[0].id = clip.id

        // 取り除いた長さの合計と、各断片の位置(詰めるときは前へ)
        let removedTotal = clip.duration - keeps.reduce(0) { $0 + $1.length }
        if ripple {
            // 詰める: 断片を前の断片の終わりにつなぐ(先頭は元の頭のまま)
            var t = clip.start
            for i in pieces.indices { pieces[i].start = t; t += pieces[i].duration }
        }

        var p = project
        var track = p.tracks[loc.track]
        track.clips.replaceSubrange(loc.index...loc.index, with: pieces)
        if ripple, removedTotal > 0 {
            let oldEnd = clip.start + clip.duration
            let ids = Set(pieces.map(\.id))
            for i in track.clips.indices where !ids.contains(track.clips[i].id) && track.clips[i].start >= oldEnd - timeEpsilon {
                track.clips[i].start = max(0, track.clips[i].start - removedTotal)
            }
        }
        p.tracks[loc.track] = track
        return (p, pieces.map(\.id))
    }
}
