import Foundation

// MARK: - マルチカムクリップ(タイムライン上の 1 つのクリップに、同期済みのアングルを内包する)
//
// 設計(`docs/マルチカムクリップ.md`):
// - クリップ自体は **普通の動画クリップ**。`src` / `offset` / `srcDuration` は常に「有効アングル」から導出した具体値を持つので、
//   プレビュー(`Renderer`)も書き出しも新しい経路なしで同じアングルを描く(`Multicam.swift` の既存の考え方と同じ)。
// - `Clip.multicam`(`MulticamClipInfo`)にアングル一覧(`MulticamAngle` = 名前・素材のクリップのコピー・同期のずれ)・有効アングル・音声アングルを持つ。
// - 基準の時刻: `基準の素材時刻 = clip.offset − angles[active].syncOffset`。どのアングルの素材時刻も `基準 + syncOffset` なので、切り替えても
//   同じ瞬間が出る。分割(`ClipEditing.split`)は offset だけを進めるので、各片がそのまま `multicam` を保ち、切り替えの計算もそのまま成り立つ。
// - 音: 既定は基準カメラ(`audioAngle` = 0)。有効アングルと別のアングルの音を選べる。音の経路(`CompoundEditing.audibleClips`)で
//   だけ src/offset を音声アングルのものに差し替える(映像は有効アングルのまま)。
// 計算は純粋(UI・ファイル読み出しなし)。

/// マルチカムクリップの中身。
public struct MulticamClipInfo: Codable, Equatable {
    /// アングル(先頭が基準カメラ)。`syncOffset` = そのアングルの素材時刻 − 基準の素材時刻(同じ瞬間どうし)。基準は 0。
    public var angles: [MulticamAngle]
    /// 映像に出すアングル(0 始まり)。
    public var activeAngle: Int
    /// 音を出すアングル(0 始まり。既定は基準 = 0)。
    public var audioAngle: Int

    public init(angles: [MulticamAngle], activeAngle: Int = 0, audioAngle: Int = 0) {
        self.angles = angles; self.activeAngle = activeAngle; self.audioAngle = audioAngle
    }

    /// 読み込みで受け入れる形か(アングルが 1 つ以上・9 個まで・番号が範囲内・ずれが有限)。外れたものは extra に回して書き戻す。
    public var isValid: Bool {
        !angles.isEmpty && angles.count <= Multicam.maxAngles
            && angles.indices.contains(activeAngle) && angles.indices.contains(audioAngle)
            && angles.allSatisfy { $0.syncOffset.isFinite }
    }

    enum CodingKeys: String, CodingKey { case angles, activeAngle, audioAngle }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        angles = try c.decode([MulticamAngle].self, forKey: .angles)
        activeAngle = try c.decodeIfPresent(Int.self, forKey: .activeAngle) ?? 0
        audioAngle = try c.decodeIfPresent(Int.self, forKey: .audioAngle) ?? 0
    }
}

public extension Multicam {
    // MARK: 作る(タイムラインに 1 つのクリップとして置く)

    enum PlaceOutcome: Equatable {
        case placed(Project, clipId: String)
        case invalid
        case locked
    }

    /// 選んだ映像クリップ(2〜9 個)を、1 つのマルチカムクリップにして基準(先頭)のクリップの位置・レイヤーに置く。
    /// 基準以外の元クリップはタイムラインから外す(アングルとしてクリップの中に持つ)。`localLags` は `makeGroup` と同じ(クリップ id → 基準に対するずれ)。
    /// 基準のクリップの見た目(エフェクト・位置・音量など)をそのまま引き継ぐ。有効アングルも音声アングルも基準(0)。
    static func placeClip(in project: Project, ids: Set<String>, localLags: [String: Double]) -> PlaceOutcome {
        guard let cands = candidates(in: project, ids: ids), let ref = cands.first, localLags.values.allSatisfy(\.isFinite) else { return .invalid }
        if cands.contains(where: { LayerEditing.isLockedClip($0.id, in: project) }) { return .locked }
        var angles: [MulticamAngle] = []
        for (i, c) in cands.enumerated() {
            let off = i == 0 ? 0 : syncOffset(reference: ref, angle: c, localLag: localLags[c.id] ?? 0)
            angles.append(MulticamAngle(name: "カメラ\(i + 1)", clip: c, syncOffset: (off * 1000).rounded() / 1000))
        }
        var p = project
        for c in cands.dropFirst() { p = ClipEditing.delete(in: p, clipId: c.id) ?? p }
        guard let loc = ClipEditing.locate(ref.id, in: p) else { return .invalid }
        var placed = ref
        placed.multicam = MulticamClipInfo(angles: angles, activeAngle: 0, audioAngle: 0)
        p.tracks[loc.track].clips[loc.index] = placed
        return .placed(p, clipId: placed.id)
    }

    // MARK: 切り替える

    /// クリップのアングル数(マルチカムクリップでなければ 0)。
    static func angleCount(_ c: Clip) -> Int { c.multicam?.angles.count ?? 0 }

    /// `c` を有効アングル `angle` に切り替えたクリップ。同じ瞬間が出るよう offset を差し替える。
    /// マルチカムクリップでない・範囲外・すでにそのアングル → nil。その区間にそのアングルの素材がないときも nil(`noFootage`)。
    static func switchedClip(_ c: Clip, to angle: Int) -> (clip: Clip, outcome: ClipSwitchOutcome) {
        guard var info = c.multicam, info.angles.indices.contains(angle), info.angles.indices.contains(info.activeAngle) else { return (c, .invalid) }
        if info.activeAngle == angle { return (c, .unchanged) }
        let refOffset = c.offset - info.angles[info.activeAngle].syncOffset
        let off = refOffset + info.angles[angle].syncOffset
        guard off >= -1e-6 else { return (c, .noFootage) }
        let target = info.angles[angle].clip
        if let sd = target.srcDuration, off + c.duration > sd + 1e-6 { return (c, .noFootage) }
        var x = c
        x.src = target.src
        x.srcDuration = target.srcDuration
        x.offset = max(0, off)
        info.activeAngle = angle
        x.multicam = info
        return (x, .switched)
    }

    enum ClipSwitchOutcome: Equatable { case switched, unchanged, noFootage, invalid }

    enum ClipCutOutcome: Equatable {
        case cut(Project)
        case unchanged
        case locked
        case noFootage
        case invalid
    }

    /// マルチカムクリップ `clipId` の有効アングルを `angle` にする。
    /// `at` が(クリップの内側で、両端から最小の長さ以上離れていれば)その位置で分割して **右側だけ** を切り替える。`at` が nil か外側なら、クリップ全体。
    /// 結果は 1 回の編集(呼び出し側が 1 回の Undo にする)。
    static func setActiveAngle(in project: Project, clipId: String, angle: Int, at t: Double? = nil) -> ClipCutOutcome {
        guard let loc = ClipEditing.locate(clipId, in: project) else { return .invalid }
        let c = project.tracks[loc.track].clips[loc.index]
        guard c.multicam != nil else { return .invalid }
        if LayerEditing.isLockedClip(clipId, in: project) { return .locked }
        var p = project
        var useSplit = false
        if let t, t.isFinite, t > c.start + ClipEditing.minDuration, t < c.start + c.duration - ClipEditing.minDuration { useSplit = true }
        if useSplit, let t {
            // 切れ目より後ろがすでにそのアングルなら何もしない(先に判定して、無駄な分割を作らない)
            guard let (l, r) = ClipEditing.split(c, at: t) else { return .invalid }
            let (x, o) = switchedClip(r, to: angle)
            switch o {
            case .switched:
                p.tracks[loc.track].clips[loc.index] = l
                p.tracks[loc.track].clips.insert(x, at: loc.index + 1)
            case .unchanged: return .unchanged
            case .noFootage: return .noFootage
            case .invalid: return .invalid
            }
        } else {
            let (x, o) = switchedClip(c, to: angle)
            switch o {
            case .switched: p.tracks[loc.track].clips[loc.index] = x
            case .unchanged: return .unchanged
            case .noFootage: return .noFootage
            case .invalid: return .invalid
            }
        }
        return .cut(p)
    }

    /// 再生位置 `t` に重なるマルチカムクリップ(上のレイヤー優先)。1〜9 キーの対象を決めるのに使う。
    static func clip(at t: Double, in project: Project) -> Clip? {
        for tr in project.tracks.reversed() where !tr.isHidden {
            if let c = tr.clips.first(where: { $0.multicam != nil && t >= $0.start && t < $0.start + $0.duration }) { return c }
        }
        return nil
    }

    // MARK: 音声アングル

    /// 音声アングルを `angle` にする(`ids` のうちマルチカムクリップ)。ロック・範囲外・変化なしは飛ばす。何も変わらなければ nil。映像は変えない。
    static func setAudioAngle(in project: Project, ids: Set<String>, angle: Int) -> Project? {
        var p = project
        for ti in p.tracks.indices where !p.tracks[ti].isLocked {
            for ci in p.tracks[ti].clips.indices where ids.contains(p.tracks[ti].clips[ci].id) && !p.tracks[ti].clips[ci].isClipLocked {
                guard var info = p.tracks[ti].clips[ci].multicam, info.angles.indices.contains(angle), info.audioAngle != angle else { continue }
                info.audioAngle = angle
                p.tracks[ti].clips[ci].multicam = info
            }
        }
        return p == project ? nil : p
    }

    /// 音の経路用: 音声アングルが有効アングルと別なら、src / offset / srcDuration を音声アングルのものにしたクリップ。そうでなければ `c` のまま。
    /// 音声アングルの素材がその区間にないとき(頭より前)は offset を 0 に丸める。
    static func audioResolved(_ c: Clip) -> Clip {
        guard let info = c.multicam, info.audioAngle != info.activeAngle,
              info.angles.indices.contains(info.audioAngle), info.angles.indices.contains(info.activeAngle) else { return c }
        let a = info.angles[info.audioAngle]
        var x = c
        x.src = a.clip.src
        x.srcDuration = a.clip.srcDuration
        x.offset = max(0, c.offset - info.angles[info.activeAngle].syncOffset + a.syncOffset)
        return x
    }
}
