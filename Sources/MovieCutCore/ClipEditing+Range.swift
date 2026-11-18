import Foundation

/// 範囲の削除: 時間の範囲 [from, to] を全レイヤーから取り除く(任意で後ろを詰める)。
extension ClipEditing {
    /// 範囲の中身を全レイヤーから取り除く。範囲の両端で既存の `split` で割ってから、範囲に完全に入る断片を消すので、
    /// offset・速度ランプ・逆再生・キーフレーム・フェードの振り分けは分割と同じ(複合クリップも分割と同じ扱いで割れる)。
    /// - Parameters:
    ///   - from, to: 取り除く範囲(秒)。[0, endTime] に切り詰める
    ///   - ripple: true なら、各レイヤーで範囲の終わり以降に始まるクリップを範囲の幅だけ左へ詰める(マーカーは動かさない)
    /// - Returns: 新しいプロジェクト。範囲が空・何にも触れない、範囲に触れるクリップがロックされている(レイヤーのロック含む)、
    ///   リップルで詰めるクリップがロックされている、のときは nil(元は変えない)。
    public static func deleteRange(in project: Project, from: Double, to: Double, ripple: Bool) -> Project? {
        deleteRange(in: project, from: from, to: to, ripple: ripple, trackIndices: nil)
    }

    /// 対象レイヤーを限った範囲の削除(範囲選択から使う)。`trackIndices` が nil なら全レイヤー(上の関数とまったく同じ)。
    /// 対象外のレイヤーは削除もリップルの詰めもせず、ロックの検査もしない(対象外のロックは削除を止めない)。
    public static func deleteRange(in project: Project, from: Double, to: Double, ripple: Bool, trackIndices: Set<Int>?) -> Project? {
        let a = max(0, from), b = min(project.endTime, to)
        let width = b - a
        guard width > timeEpsilon else { return nil }

        // ロック: 範囲に触れるクリップ、リップルなら詰められるクリップがロックされていれば、全体を中止する
        for (ti, tr) in project.tracks.enumerated() {
            if let s = trackIndices, !s.contains(ti) { continue }
            for c in tr.clips {
                let end = c.start + c.duration
                let touches = c.start < b - timeEpsilon && end > a + timeEpsilon
                let moves = ripple && c.start >= b - timeEpsilon
                if (touches || moves) && (tr.isLocked || c.isClipLocked) { return nil }
            }
        }

        var p = project
        for ti in p.tracks.indices {
            if let s = trackIndices, !s.contains(ti) { continue }
            var out: [Clip] = []
            for c in p.tracks[ti].clips {
                // 両端で割る(端のごく近くでは割らない)。右の断片は新しい id、左は元の id のまま
                var pieces = [c]
                for t in [a, b] {
                    guard let last = pieces.last, t > last.start + timeEpsilon, t < last.start + last.duration - timeEpsilon,
                          let (l, r) = split(last, at: t) else { continue }
                    pieces[pieces.count - 1] = l
                    pieces.append(r)
                }
                for var piece in pieces {
                    let end = piece.start + piece.duration
                    let mid = piece.start + piece.duration / 2
                    if piece.start >= a - timeEpsilon, end <= b + timeEpsilon, mid > a, mid < b { continue }   // 範囲の中 = 削除
                    if ripple, piece.start >= b - timeEpsilon { piece.start = max(0, piece.start - width) }
                    out.append(piece)
                }
            }
            p.tracks[ti].clips = out
        }
        return p == project ? nil : p
    }
}
