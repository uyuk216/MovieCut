import Foundation

/// J/Lカット(スプリット編集)の純粋な計算。映像の境界はそのままに、音だけのクリップ
/// (音声・ボイス)の境界だけをロールして、映像と音の切り替わりをずらす。
/// - Jカット: 次の音が映像の切り替わりより先に出る(音の境界を前へ動かす)。
/// - Lカット: 前の音が映像の切り替わりの後まで残る(音の境界を後ろへ動かす)。
/// 前提: アンカーのクリップの境界(終わり側を優先)と同じ時刻に、別のレイヤーで映像クリップ同士の
/// 境界があり、音だけのクリップ同士の境界もあること。どちらか欠ければ nil(近似操作には倒さない)。
/// 動きはロールの規則そのまま(素材の範囲・最短の長さで止まる)。結果は 1 つの Project なので Undo は 1 回。
public enum ClipSplitEdit {
    /// 音だけのクリップ(映像を持たない)か。
    public static func isSoundOnly(_ clip: Clip) -> Bool { clip.type == .audio || clip.type == .voice }

    /// 映像の境界として数えるクリップか(音だけ・ぼかし・調整・ビジュアライザは数えない)。
    public static func isPicture(_ clip: Clip) -> Bool {
        switch clip.type {
        case .video, .image, .text, .shape, .tachie, .compound, .scene: return true
        default: return false
        }
    }

    /// アンカーの境界時刻(終わり側に隣があれば終わり、無ければ頭)。
    public static func boundaryTime(for clipId: String, in project: Project) -> Double? {
        guard let loc = ClipEditing.locate(clipId, in: project) else { return nil }
        let c = project.tracks[loc.track].clips[loc.index]
        if ClipRollSlip.rightNeighbor(of: clipId, in: project) != nil { return c.start + c.duration }
        if ClipRollSlip.leftNeighbor(of: clipId, in: project) != nil { return c.start }
        return nil
    }

    /// 時刻 `t` でぴったり隣り合い、両方とも条件に合う (左, 右) の組(最初に見つかったもの)。
    private static func pair(at t: Double, in project: Project, where ok: (Clip) -> Bool) -> (left: String, right: String)? {
        for tr in project.tracks {
            for c in tr.clips where abs(c.start + c.duration - t) <= ClipRollSlip.adjacencyTolerance {
                guard ok(c), let r = ClipRollSlip.rightNeighbor(of: c.id, in: project),
                      let rl = ClipEditing.locate(r, in: project), ok(project.tracks[rl.track].clips[rl.index]) else { continue }
                return (c.id, r)
            }
        }
        return nil
    }

    /// 時刻 `t` にある、音だけのクリップ同士の境界。
    public static func soundPair(at t: Double, in project: Project) -> (left: String, right: String)? {
        pair(at: t, in: project, where: isSoundOnly)
    }

    /// 時刻 `t` に映像クリップ同士の境界があるか。
    public static func hasPictureBoundary(at t: Double, in project: Project) -> Bool {
        pair(at: t, in: project, where: isPicture) != nil
    }

    /// J/Lカットができない理由(日本語)。使えるなら nil。
    public static func splitEditBlockedReason(in project: Project, anchorClipId: String) -> String? {
        guard let t = boundaryTime(for: anchorClipId, in: project) else { return "隣り合うクリップとの境界がありません" }
        guard let s = soundPair(at: t, in: project) else { return "その境界に音声・ボイスだけのクリップの境界がありません" }
        guard hasPictureBoundary(at: t, in: project) else { return "その境界に映像クリップの境界がありません" }
        if LayerEditing.isLockedClip(s.left, in: project) || LayerEditing.isLockedClip(s.right, in: project) {
            return "ロックされたレイヤー・クリップは編集できません"
        }
        return nil
    }

    /// 音の境界だけを `deltaT` 秒動かす(正 = 後ろへ = Lカット、負 = 前へ = Jカット)。映像の境界は動かさない。
    /// 素材の範囲・最短の長さで止まる。動かせない・変わらないときは nil。
    public static func splitEdit(in project: Project, anchorClipId: String, deltaT: Double) -> Project? {
        guard deltaT.isFinite, deltaT != 0,
              splitEditBlockedReason(in: project, anchorClipId: anchorClipId) == nil,
              let t = boundaryTime(for: anchorClipId, in: project),
              let s = soundPair(at: t, in: project) else { return nil }
        return ClipRollSlip.roll(in: project, leftClipId: s.left, deltaT: deltaT)
    }

    /// コマ数で動かす版(正 = Lカット、負 = Jカット)。
    public static func splitEdit(in project: Project, anchorClipId: String, frames: Int) -> Project? {
        splitEdit(in: project, anchorClipId: anchorClipId, deltaT: Double(frames) * ClipNudge.frameSeconds(fps: project.fps))
    }

    /// 動かす量の符号から見た呼び名(正 = Lカット、負 = Jカット、0 は nil)。
    public static func kind(forDelta deltaT: Double) -> String? {
        if deltaT > 0 { return "Lカット" }
        if deltaT < 0 { return "Jカット" }
        return nil
    }
}
