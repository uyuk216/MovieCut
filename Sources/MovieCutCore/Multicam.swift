import Foundation

// MARK: - マルチカメラ編集
//
// 同じ出来事を別のカメラで撮った複数の映像クリップ(角度)を、音の相互相関でそろえ、アングルを切り替えながら 1 本にする。
// - グループ(`MulticamGroup`)は角度の一覧と同期のずれ、切り替えの結果を置く「ターゲットのレイヤー」の id を持つ。使ったときだけ Project に書く。
// - 切り替えた結果は **普通のクリップ**(その角度の素材を、ずれを足した位置から使う分割クリップ)なので、プレビュー・書き出しに新しい経路は要らない。
// - 音は最初の角度(基準)のクリップのものを使う。切り替えのクリップは無音(volume 0)、基準以外の元クリップも無音にする。
// 計算は純粋(ファイルの読み出しは呼び出し側)。

/// マルチカメラの 1 つの角度。
public struct MulticamAngle: Codable, Equatable {
    /// 角度の名前(表示用)。
    public var name: String
    /// グループを作ったときの元クリップのコピー(素材・使う区間・エフェクトなど)。切り替えのクリップはこれから作る。
    public var clip: Clip
    /// 同期のずれ(秒): この角度の素材の時刻 − 基準の角度の素材の時刻(同じ瞬間どうし)。基準は 0。
    public var syncOffset: Double

    public init(name: String, clip: Clip, syncOffset: Double) {
        self.name = name; self.clip = clip; self.syncOffset = syncOffset
    }
}

public struct MulticamGroup: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    /// 最初が基準(音もこれを使う)。1〜9 のキーが 1 番目〜9 番目の角度に当たる。
    public var angles: [MulticamAngle]
    /// 切り替えの結果を置くレイヤー(`Track.id`)。
    public var targetTrackId: String

    public init(id: String? = nil, name: String, angles: [MulticamAngle], targetTrackId: String) {
        self.id = id ?? newId(); self.name = name; self.angles = angles; self.targetTrackId = targetTrackId
    }

    /// 基準の角度が占める時間(グループの時間軸)。
    public var range: ClosedRange<Double>? {
        guard let r = angles.first?.clip else { return nil }
        return r.start...(r.start + r.duration)
    }
}

public enum Multicam {
    public static let maxAngles = 9
    public static let layerName = "マルチカメラ"

    // MARK: 作る

    /// 角度にできるクリップか(素材のある映像で、速度変更・逆再生・フリーズ・速度ランプがない)。
    public static func isAngleCandidate(_ c: Clip) -> Bool {
        c.type == .video && SilenceDetector.supports(c) && !c.isFreeze && c.effectiveSpeed == 1
    }

    /// 選択から、基準を先頭にした角度の元クリップの並び(頭の早い順、同じなら下のレイヤー順)。作れなければ nil。
    public static func candidates(in project: Project, ids: Set<String>) -> [Clip]? {
        guard ids.count >= 2, ids.count <= maxAngles else { return nil }
        var found: [(clip: Clip, track: Int)] = []
        for (ti, tr) in project.tracks.enumerated() {
            for c in tr.clips where ids.contains(c.id) { found.append((c, ti)) }
        }
        guard found.count == ids.count, found.allSatisfy({ isAngleCandidate($0.clip) }) else { return nil }
        found.sort { $0.clip.start != $1.clip.start ? $0.clip.start < $1.clip.start : $0.track < $1.track }
        return found.map(\.clip)
    }

    public static let selectionHint = "映像のクリップを 2〜9 個選んでください(速度変更・逆再生・フリーズのないもの)"

    public static func createDisabledReason(in project: Project, ids: Set<String>) -> String? {
        candidates(in: project, ids: ids) == nil ? selectionHint : nil
    }

    /// 音の包絡(10 ms ごと)から、基準に対する同期のずれ(クリップの頭からの秒。正 = 角度のほうが後ろにずれている)を求める。合わせられなければ nil。
    /// `AudioSyncEditing.lagSeconds` と同じ計算(精度は包絡の窓 = 10 ms)。
    public static func localLag(reference: [Float], angle: [Float]) -> Double? {
        AudioSyncEditing.lagSeconds(video: reference, audio: angle)
    }

    /// クリップの頭からのずれ `lag` を、素材の時刻どうしのずれにする(使っている区間の頭が違うぶんを足す)。
    public static func syncOffset(reference: Clip, angle: Clip, localLag lag: Double) -> Double {
        (angle.offset - reference.offset) + lag
    }

    public enum CreateOutcome: Equatable {
        case created(Project, groupId: String)
        case invalid
        case locked
    }

    /// グループを作る。`localLags` はクリップ id → 基準に対するずれ(秒。基準と、無いものは 0 = 手動の初期値)。
    /// 結果を置く新しいレイヤーを一番手前に足し、基準以外の元クリップを無音にする(音は基準だけ)。
    public static func makeGroup(in project: Project, ids: Set<String>, localLags: [String: Double], name: String? = nil) -> CreateOutcome {
        guard let cands = candidates(in: project, ids: ids), let ref = cands.first, localLags.values.allSatisfy(\.isFinite) else { return .invalid }
        if cands.contains(where: { LayerEditing.isLockedClip($0.id, in: project) }) { return .locked }
        var p = project
        var angles: [MulticamAngle] = []
        for (i, c) in cands.enumerated() {
            let off = i == 0 ? 0 : syncOffset(reference: ref, angle: c, localLag: localLags[c.id] ?? 0)
            angles.append(MulticamAngle(name: "カメラ\(i + 1)", clip: c, syncOffset: (off * 1000).rounded() / 1000))
        }
        let track = Track(name: layerName)
        p.tracks.append(track)
        for c in cands.dropFirst() {
            if let loc = ClipEditing.locate(c.id, in: p) { p.tracks[loc.track].clips[loc.index].volume = 0 }
        }
        let g = MulticamGroup(name: name ?? "マルチカメラ\(project.multicams.count + 1)", angles: angles, targetTrackId: track.id)
        p.multicams.append(g)
        return .created(p, groupId: g.id)
    }

    // MARK: グループの探索

    /// 時刻 `t` で使うグループ(基準の角度が `t` を含み、結果のレイヤーが残っているもの。複数なら先に作ったもの)。
    public static func activeGroup(in project: Project, at t: Double) -> MulticamGroup? {
        project.multicams.first { g in
            (g.range.map { t >= $0.lowerBound && t < $0.upperBound } ?? false) && project.tracks.contains { $0.id == g.targetTrackId }
        }
    }

    // MARK: 切り替える

    public enum CutOutcome: Equatable {
        case cut(Project)
        /// すでにその角度になっている
        case unchanged
        case locked
        /// 基準の範囲の外
        case outsideRange
        /// その角度の素材が、この区間にない
        case noFootage
        case invalid
    }

    /// 再生位置 `t` から次の切り替えの手前(無ければ基準の終わり)まで、角度 `angle`(0 始まり)に切り替える。
    /// 結果のレイヤーの上で、`t` を含むクリップは `t` で分割して右側を置き換え、何もない所は新しいクリップを足す。
    /// 1 回の編集(呼び出し側が 1 回の Undo にする)。
    public static func cut(in project: Project, groupId: String, angle: Int, at t: Double) -> CutOutcome {
        guard t.isFinite, let g = project.multicams.first(where: { $0.id == groupId }), g.angles.indices.contains(angle),
              let ti = project.tracks.firstIndex(where: { $0.id == g.targetTrackId }), let range = g.range else { return .invalid }
        if project.tracks[ti].isLocked { return .locked }
        let ref = g.angles[0].clip
        guard t >= range.lowerBound - 1e-9, t < range.upperBound - ClipEditing.minDuration + 1e-9 else { return .outsideRange }
        let t = max(t, range.lowerBound)
        var clips = project.tracks[ti].clips
        if clips.contains(where: { $0.isClipLocked && $0.start < t + ClipEditing.minDuration && $0.start + $0.duration > t }) { return .locked }

        // 置き換える区間 [t, segEnd)
        var cover = clips.firstIndex { $0.start <= t + ClipEditing.timeEpsilon && $0.start + $0.duration > t + ClipEditing.timeEpsilon }
        var segEnd: Double
        if let ci = cover {
            segEnd = clips[ci].start + clips[ci].duration
            if clips[ci].src == g.angles[angle].clip.src { return .unchanged }
            // t が頭ぴったりでなければ分割(右側が置き換え対象)
            if t - clips[ci].start > ClipEditing.timeEpsilon, let (l, r) = ClipEditing.split(clips[ci], at: t) {
                clips[ci] = l
                clips.insert(r, at: ci + 1)
                cover = ci + 1
            }
            if let c2 = cover { clips.remove(at: c2) }
        } else {
            segEnd = min(range.upperBound, clips.filter { $0.start > t }.map(\.start).min() ?? range.upperBound)
        }
        let len = segEnd - t
        guard len >= ClipEditing.minDuration - 1e-9 else { return .invalid }
        guard let made = angleClip(g, angle: angle, start: t, duration: len, reference: ref) else { return .noFootage }
        clips.append(made)
        clips.sort { $0.start < $1.start }
        var p = project
        p.tracks[ti].clips = clips
        return p == project ? .unchanged : .cut(p)
    }

    /// 角度 `angle` を、グループの時刻 `start` から `duration` 秒だけ使うクリップ。素材がその区間にないときは nil。
    public static func angleClip(_ g: MulticamGroup, angle: Int, start: Double, duration: Double, reference ref: Clip) -> Clip? {
        var c = g.angles[angle].clip
        let refSource = ref.offset + (start - ref.start)          // 基準の素材の時刻
        let off = refSource + g.angles[angle].syncOffset         // この角度の素材の時刻
        guard off >= -1e-6 else { return nil }
        if let sd = c.srcDuration, off + duration > sd + 1e-6 { return nil }
        c.id = newId()
        c.start = start
        c.duration = duration
        c.offset = max(0, off)
        c.volume = 0                      // 音は基準のクリップから
        c.transitionIn = nil; c.transitionOut = nil
        c.fadeIn = nil; c.fadeOut = nil
        c.keyframes = [:]
        return c
    }
}
