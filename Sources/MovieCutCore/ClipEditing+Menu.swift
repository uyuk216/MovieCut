import Foundation

/// M7: クリップメニュー(複製・切り落とし・すき間を詰めて削除・前後選択・レイヤー移動)と、
/// 移動メニュー(編集点・セリフ・時間指定)の純粋な計算。
extension ClipEditing {
    /// 時刻の比較に使う幅(秒)。
    public static let timeEpsilon = 1e-6

    // MARK: 複製

    /// [start, end) が、`excluding` 以外のクリップと重ならない(端が接するだけなら重ならない)。
    static func isFree(_ track: Track, start: Double, end: Double, excluding: String? = nil) -> Bool {
        track.clips.allSatisfy { c in
            c.id == excluding || c.start + c.duration <= start + timeEpsilon || c.start >= end - timeEpsilon
        }
    }

    /// クリップの複製: 元のすぐ後ろ(元の終わりの時刻)に同じレイヤーで置く。そこが他のクリップと重なるなら、
    /// その時刻に空きがある最初のレイヤーへ。どのレイヤーも空いていなければ、一番下に新しいレイヤーを足す。
    /// 新しい id。複製は元のすぐ後ろ(配列の中でも)に入れる。長さ 0 のクリップは重ならないので同じレイヤー。
    public static func duplicate(in project: Project, clipId: String) -> (project: Project, newId: String)? {
        guard let loc = locate(clipId, in: project) else { return nil }
        var p = project
        let src = p.tracks[loc.track].clips[loc.index]
        var copy = CompoundEditing.freshIds(src)   // 複合の中の子にも新しい id
        copy.start = src.start + src.duration
        let end = copy.start + copy.duration
        if isFree(p.tracks[loc.track], start: copy.start, end: end) {
            p.tracks[loc.track].clips.insert(copy, at: loc.index + 1)
        } else if let ti = p.tracks.indices.first(where: { !p.tracks[$0].isLocked && isFree(p.tracks[$0], start: copy.start, end: end) }) {
            p.tracks[ti].clips.append(copy)
        } else {
            var t = Track(name: "レイヤー\(p.tracks.count + 1)")
            t.clips = [copy]
            p.tracks.append(t)
        }
        return (p, copy.id)
    }

    // MARK: 再生位置での切り落とし

    /// 再生位置 `t` がクリップの中(端は含まない)にあるか = 切り落とせる。
    public static func canTrim(_ clip: Clip, at t: Double) -> Bool {
        t > clip.start + timeEpsilon && t < clip.start + clip.duration - timeEpsilon
    }

    /// `t` より前を切り落とす: 頭を `t` に、長さを (終わり − t) に。素材の時間軸があるクリップは offset に切った長さを足す
    /// (左端トリム / 分割の右側と同じ計算)。残りは元の時刻のまま(前に詰めない)。
    public static func trimBefore(in project: Project, clipId: String, at t: Double) -> Project? {
        guard let loc = locate(clipId, in: project), canTrim(project.tracks[loc.track].clips[loc.index], at: t) else { return nil }
        var p = project
        var c = p.tracks[loc.track].clips[loc.index]
        let cut = t - c.start
        let ramp = c.rampPoints
        c.duration -= cut
        c.start = t
        // 順再生は offset が進む。逆再生は頭が素材の終わりなので offset はそのまま(長さだけ縮む)
        if let ramp, movesSource(c) {
            c.offset += SpeedRamp.integral(ramp, upTo: cut)
            c.speedRamp = SpeedRamp.split(ramp, at: cut).right
        } else if movesSource(c) && !c.effectiveReverse { c.offset += cut * c.effectiveSpeed }
        if c.hasKeyframes { c.keyframes = Animation.shifted(c.keyframes, by: -cut) }
        p.tracks[loc.track].clips[loc.index] = c
        return p
    }

    /// `t` より後ろを切り落とす: 長さを (t − 頭) に。頭と offset はそのまま(逆再生は終わりが素材の頭側なので offset が進む)。
    public static func trimAfter(in project: Project, clipId: String, at t: Double) -> Project? {
        guard let loc = locate(clipId, in: project), canTrim(project.tracks[loc.track].clips[loc.index], at: t) else { return nil }
        var p = project
        var c = p.tracks[loc.track].clips[loc.index]
        let oldDuration = c.duration
        let ramp = c.rampPoints
        c.duration = t - c.start
        if let ramp { c.speedRamp = SpeedRamp.fit(ramp, to: c.duration) }
        // 逆再生は終わりが素材の頭側(offset)なので、切った分だけ offset が進む
        else if movesSource(c) && c.effectiveReverse { c.offset += (oldDuration - c.duration) * c.effectiveSpeed }
        p.tracks[loc.track].clips[loc.index] = c
        return p
    }

    // MARK: すき間を詰めて削除

    /// 消したクリップの終わり以降に始まる、同じレイヤーのクリップを、消したクリップの長さだけ左へ詰める(0 未満にはしない)。
    /// 他のレイヤーには触らない。消したクリップにかかっていた(途中から始まる)クリップは動かさない。
    public static func rippleDelete(in project: Project, clipId: String) -> Project? {
        guard let loc = locate(clipId, in: project) else { return nil }
        var p = project
        let removed = p.tracks[loc.track].clips.remove(at: loc.index)
        let end = removed.start + removed.duration
        for i in p.tracks[loc.track].clips.indices where p.tracks[loc.track].clips[i].start >= end - timeEpsilon {
            p.tracks[loc.track].clips[i].start = max(0, p.tracks[loc.track].clips[i].start - removed.duration)
        }
        return p
    }

    // MARK: 前後のクリップを選ぶ

    /// 全レイヤーのクリップを (頭の時刻, レイヤー番号, 配列の順) に並べた id。
    public static func clipsByStart(_ project: Project) -> [Clip] {
        var all: [(Clip, Int, Int)] = []
        for (ti, tr) in project.tracks.enumerated() { for (ci, c) in tr.clips.enumerated() { all.append((c, ti, ci)) } }
        all.sort { a, b in
            if a.0.start != b.0.start { return a.0.start < b.0.start }
            if a.1 != b.1 { return a.1 < b.1 }
            return a.2 < b.2
        }
        return all.map(\.0)
    }

    /// 選択中のクリップの前(forward=false)/後(true)のクリップの id。選択が無いときは、再生位置より後ろ(前)で
    /// 一番近い頭のクリップ。無ければ nil。
    public static func adjacentClipId(in project: Project, from selectedId: String?, forward: Bool, playhead: Double) -> String? {
        let sorted = clipsByStart(project)
        if let id = selectedId, let i = sorted.firstIndex(where: { $0.id == id }) {
            let j = forward ? i + 1 : i - 1
            return sorted.indices.contains(j) ? sorted[j].id : nil
        }
        if forward { return sorted.first { $0.start >= playhead - timeEpsilon }?.id }
        return sorted.last { $0.start < playhead - timeEpsilon }?.id
    }

    /// `adjacentClipId` が nil でないかを、並べ替えず 1 回の走査で調べる(メニューの有効・無効用。再生中も毎コマ呼ばれうる)。
    public static func hasAdjacentClip(in project: Project, from selectedId: String?, forward: Bool, playhead: Double) -> Bool {
        var selKey: (Double, Int, Int)?
        if let id = selectedId {
            for (ti, tr) in project.tracks.enumerated() {
                if let ci = tr.clips.firstIndex(where: { $0.id == id }) { selKey = (tr.clips[ci].start, ti, ci) }
            }
        }
        for (ti, tr) in project.tracks.enumerated() {
            for (ci, c) in tr.clips.enumerated() {
                if let k = selKey {
                    if c.id == selectedId { continue }
                    let less = (c.start, ti, ci) < k
                    if forward != less { return true }
                } else if forward ? c.start >= playhead - timeEpsilon : c.start < playhead - timeEpsilon {
                    return true
                }
            }
        }
        return false
    }

    // MARK: レイヤー移動

    /// 隣のレイヤーへ移す(`delta` = −1 は画面で一つ上の行 = 配列の一つ前)。時刻は変えず、レイヤーは増やさない。端なら nil。
    /// 行き先の末尾に足す(ドラッグ移動と同じ)。
    public static func moveToAdjacentLayer(in project: Project, clipId: String, delta: Int) -> Project? {
        guard let loc = locate(clipId, in: project) else { return nil }
        let to = loc.track + delta
        guard delta != 0, project.tracks.indices.contains(to) else { return nil }
        var p = project
        let c = p.tracks[loc.track].clips.remove(at: loc.index)
        p.tracks[to].clips.append(c)
        return p
    }

    // MARK: 移動メニュー(編集点・セリフ)

    /// 編集点: 0、プロジェクトの終わり、全レイヤーの全クリップの頭と終わり。時刻順で重複なし。
    public static func editPoints(_ project: Project) -> [Double] {
        var pts: [Double] = [0, project.endTime]
        for c in project.allClips { pts.append(c.start); pts.append(c.start + c.duration) }
        return uniqueSorted(pts)
    }

    /// ボイスクリップの頭(時刻順で重複なし)。
    public static func voiceStarts(_ project: Project) -> [Double] {
        uniqueSorted(project.allClips.filter { $0.type == .voice }.map(\.start))
    }

    private static func uniqueSorted(_ v: [Double]) -> [Double] {
        var out: [Double] = []
        for x in v.sorted() where x.isFinite && x >= 0 { if let l = out.last, x - l <= timeEpsilon { continue }; out.append(x) }
        return out
    }

    /// `t` の直前(未満)の点。`points` は走査だけ(並べ替え不要)。
    public static func previousPoint(_ points: [Double], before t: Double) -> Double? {
        points.filter { $0 < t - timeEpsilon }.max()
    }

    public static func nextPoint(_ points: [Double], after t: Double) -> Double? {
        points.filter { $0 > t + timeEpsilon }.min()
    }

    /// 前後の編集点が在るか(メニューの有効・無効用。並べ替えず 1 回の走査で済ませる)。
    public static func hasEditPoint(_ project: Project, before t: Double) -> Bool {
        if t > timeEpsilon { return true }   // 0 がある
        return false
    }

    public static func hasEditPoint(_ project: Project, after t: Double) -> Bool {
        if project.endTime > t + timeEpsilon { return true }   // 終わりがある(クリップの頭と終わりは終わり以下)
        return false
    }

    // MARK: 時間指定

    /// 「12.5」「1:23」「1:23.5」「00:01:23.50」(全角も可)を秒にする。読めなければ nil。
    /// 秒 → 分:秒 → 時:分:秒。2 つ目以降の区切りでは、分・秒は 0〜59(秒は小数可)。負・空・NaN は nil。
    public static func parseTimecode(_ raw: String) -> Double? {
        let half = raw.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? raw
        let s = half.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "：", with: ":")
        guard !s.isEmpty else { return nil }
        let parts = s.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard (1...3).contains(parts.count) else { return nil }
        func integer(_ x: String) -> Int? { x.isEmpty || !x.allSatisfy(\.isASCII) || !x.allSatisfy(\.isNumber) ? nil : Int(x) }
        func seconds(_ x: String) -> Double? {
            guard !x.isEmpty, x.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }), x.filter({ $0 == "." }).count <= 1,
                  x != ".", let v = Double(x), v.isFinite else { return nil }
            return v
        }
        if parts.count == 1 { return seconds(parts[0]) }
        guard let sec = seconds(parts[parts.count - 1]), sec < 60 else { return nil }
        guard let min = integer(parts[parts.count - 2]) else { return nil }
        if parts.count == 2 { return Double(min) * 60 + sec }
        guard let hour = integer(parts[0]), min < 60 else { return nil }
        return Double(hour) * 3600 + Double(min) * 60 + sec
    }

    /// 移動先を [0, 終わり] に収める。
    public static func clampJump(_ t: Double, end: Double) -> Double {
        min(max(0, t), max(0, end))
    }
}
