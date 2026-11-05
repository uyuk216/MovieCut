import Foundation

/// ロール編集とスリップ編集(画面にも Undo にも依存しない純粋な計算)。
/// - ロール: 同じレイヤーでぴったり隣り合う 2 つのクリップの境界を動かす。片方の終わりを縮め、もう片方の頭を同じだけ延ばす(逆も同じ)。全体の長さは変わらない。
/// - スリップ: クリップの頭の位置と長さはそのままで、使う素材の区間(offset)だけをずらす。
/// どちらも素材の範囲を越えず(越える分は手前で止める)、ロックされたクリップ・レイヤーは断る。何も変わらないときは nil(Undo に載せない)。
/// 動かす量は「タイムライン上の秒」。トリムと同じ規則(速度・逆再生・速度ランプ)で素材側の動きに直す。
public enum ClipRollSlip {
    /// 隣り合うとみなす隙間(秒)。
    public static let adjacencyTolerance = 1e-6

    // MARK: 隣り合うクリップ

    /// `clipId` の終わりにぴったり頭がつながっている、同じレイヤーのクリップ。
    public static func rightNeighbor(of clipId: String, in project: Project) -> String? {
        guard let loc = ClipEditing.locate(clipId, in: project) else { return nil }
        let tr = project.tracks[loc.track]
        let end = tr.clips[loc.index].start + tr.clips[loc.index].duration
        return tr.clips.first { $0.id != clipId && abs($0.start - end) <= adjacencyTolerance }?.id
    }

    /// `clipId` の頭にぴったり終わりがつながっている、同じレイヤーのクリップ。
    public static func leftNeighbor(of clipId: String, in project: Project) -> String? {
        guard let loc = ClipEditing.locate(clipId, in: project) else { return nil }
        let tr = project.tracks[loc.track]
        let start = tr.clips[loc.index].start
        return tr.clips.first { $0.id != clipId && abs($0.start + $0.duration - start) <= adjacencyTolerance }?.id
    }

    /// メニュー用: 選んだクリップの「終わり側の境界」(あれば)、無ければ「頭側の境界」の (左, 右)。
    public static func boundary(for clipId: String, in project: Project) -> (left: String, right: String)? {
        if let r = rightNeighbor(of: clipId, in: project) { return (clipId, r) }
        if let l = leftNeighbor(of: clipId, in: project) { return (l, clipId) }
        return nil
    }

    // MARK: ロック

    private static func locked(_ id: String, _ project: Project) -> Bool { LayerEditing.isLockedClip(id, in: project) }

    // MARK: ロール

    /// 使えない理由(日本語)。使えるなら nil。
    public static func rollBlockedReason(in project: Project, clipId: String) -> String? {
        guard let b = boundary(for: clipId, in: project) else { return "同じレイヤーでぴったり隣り合うクリップがありません" }
        if locked(b.left, project) || locked(b.right, project) { return "ロックされたレイヤー・クリップは編集できません" }
        return nil
    }

    /// 境界を `deltaT` 秒動かす(正 = 後ろへ: 左の終わりを延ばし右の頭を縮める。負 = 前へ)。
    /// 素材の範囲・最短の長さで、動かせる量が `deltaT` より小さければその量まで。動かせない・変わらないときは nil。
    public static func roll(in project: Project, leftClipId: String, deltaT: Double) -> Project? {
        guard deltaT.isFinite, deltaT != 0,
              let rightId = rightNeighbor(of: leftClipId, in: project),
              !locked(leftClipId, project), !locked(rightId, project) else { return nil }
        guard let a = applied(project, leftClipId, rightId, deltaT) else { return nil }
        // 両側とも動けた量(符号が同じ小さい方)に合わせて、もう一度計算する
        let moved = deltaT > 0 ? min(a.left, a.right) : max(a.left, a.right)
        guard moved != 0, (moved > 0) == (deltaT > 0) else { return nil }
        guard let b = applied(project, leftClipId, rightId, moved) else { return nil }
        return b.project == project ? nil : b.project
    }

    /// 左の終わり・右の頭を `d` 動かした結果と、それぞれが実際に動いた量。
    private static func applied(_ project: Project, _ leftId: String, _ rightId: String, _ d: Double) -> (project: Project, left: Double, right: Double)? {
        guard let ll = ClipEditing.locate(leftId, in: project), let rl = ClipEditing.locate(rightId, in: project) else { return nil }
        let l0 = project.tracks[ll.track].clips[ll.index], r0 = project.tracks[rl.track].clips[rl.index]
        let t1 = ClipEditing.trimRight(in: project, clipId: leftId, deltaT: d, playhead: 0, pps: 1, snapEnabled: false).project
        let t2 = ClipEditing.trimLeft(in: t1, clipId: rightId, deltaT: d, playhead: 0, pps: 1, snapEnabled: false).project
        guard let l1 = ClipEditing.locate(leftId, in: t2), let r1 = ClipEditing.locate(rightId, in: t2) else { return nil }
        let lc = t2.tracks[l1.track].clips[l1.index], rc = t2.tracks[r1.track].clips[r1.index]
        return (t2, lc.duration - l0.duration, rc.start - r0.start)
    }

    /// コマ数で動かす版(負 = 前へ)。
    public static func roll(in project: Project, leftClipId: String, frames: Int) -> Project? {
        roll(in: project, leftClipId: leftClipId, deltaT: Double(frames) * ClipNudge.frameSeconds(fps: project.fps))
    }

    // MARK: スリップ

    /// スリップできるクリップか(素材の時間軸があり、フリーズでない)。
    public static func canSlip(_ clip: Clip) -> Bool { ClipEditing.movesSource(clip) }

    public static func slipBlockedReason(in project: Project, clipId: String) -> String? {
        guard let loc = ClipEditing.locate(clipId, in: project) else { return "クリップを選んでください" }
        if locked(clipId, project) { return "ロックされたレイヤー・クリップは編集できません" }
        if !canSlip(project.tracks[loc.track].clips[loc.index]) { return "動画・音声・ボイス・複合クリップを選んでください(フリーズは対象外)" }
        return nil
    }

    /// 使う素材の区間を `deltaT` 秒(タイムライン上の長さ。速度をかけた分が素材の時間)だけ後ろへずらす(負 = 前へ)。
    /// 頭の位置・長さ・キーフレームは動かさない。素材の頭(0)より前、終わりより後ろへは行かない。
    public static func slip(in project: Project, clipId: String, deltaT: Double) -> Project? {
        guard deltaT.isFinite, deltaT != 0, slipBlockedReason(in: project, clipId: clipId) == nil,
              let loc = ClipEditing.locate(clipId, in: project) else { return nil }
        var p = project
        var c = p.tracks[loc.track].clips[loc.index]
        let rate = c.rampPoints?.first?.v ?? c.effectiveSpeed
        // 使っている素材の長さ(速度ランプは積分)
        let window = c.rampPoints.map { SpeedRamp.integral($0, upTo: c.duration) } ?? c.duration * c.effectiveSpeed
        var target = c.offset + deltaT * rate
        let upper = c.srcDuration.map { max(c.offset, $0 - window) } ?? Double.infinity
        target = min(max(0, target), upper)
        guard abs(target - c.offset) > 1e-12 else { return nil }
        c.offset = target
        p.tracks[loc.track].clips[loc.index] = c
        return p
    }

    public static func slip(in project: Project, clipId: String, frames: Int) -> Project? {
        slip(in: project, clipId: clipId, deltaT: Double(frames) * ClipNudge.frameSeconds(fps: project.fps))
    }
}
