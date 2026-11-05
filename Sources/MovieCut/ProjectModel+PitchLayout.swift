import Foundation
import MovieCutCore

/// 音MAD 向け: 音階で複製・ビートに合わせて並べる(メニュー・シートが呼ぶ)。計算は `PitchLayout`(Core)。
/// ここは Undo(1 操作 = 1 回)・選択・状態表示だけ。何も変わらない操作は Undo に積まない。
extension ProjectModel {
    static let scaleUndoName = "音階で複製"
    static let beatPlaceUndoName = "ビートに合わせて並べる"

    /// 対象にできるクリップ(1 つだけ選んでいて、音があり、ロックされていない)。
    private var pitchLayoutTarget: Clip? {
        guard !isLocked, selectedClipIDs.count <= 1, let c = selectedClip, PitchLayout.supports(c, in: project) else { return nil }
        return c
    }

    func openScaleSheet() {
        guard let c = pitchLayoutTarget else { return }
        scaleClipId = c.id
        showScaleSheet = true
    }

    func openBeatPlaceSheet() {
        guard let c = pitchLayoutTarget, !PitchLayout.markerTimes(in: project, from: c.start, beatsOnly: false).isEmpty else { return }
        beatPlaceClipId = c.id
        showBeatPlaceSheet = true
    }

    /// 音階で複製する。全体で 1 回の Undo。並べるものが無ければ false。
    @discardableResult
    func applyScaleDuplicate(clipId: String, scale: PitchScale, rootShift: Int, count: Int, descending: Bool) -> Bool {
        guard !isLocked, let c = clip(clipId) else { return false }
        let plan = PitchLayout.scalePlan(clip: c, scale: scale, rootShift: rootShift, count: count, descending: descending)
        return commitPitchLayout(clipId: clipId, plan: plan, undo: Self.scaleUndoName, what: "音階")
    }

    /// マーカーの位置に並べる。全体で 1 回の Undo。
    @discardableResult
    func applyBeatPlace(clipId: String, beatsOnly: Bool, pitchStep: Double, limit: Int) -> Bool {
        guard !isLocked, let c = clip(clipId) else { return false }
        let times = PitchLayout.markerTimes(in: project, from: c.start, beatsOnly: beatsOnly)
        let plan = PitchLayout.beatPlan(clip: c, times: times, pitchStep: pitchStep, limit: limit)
        return commitPitchLayout(clipId: clipId, plan: plan, undo: Self.beatPlaceUndoName, what: "ビート")
    }

    private func commitPitchLayout(clipId: String, plan: (steps: [PitchStep], truncated: Int), undo: String, what: String) -> Bool {
        guard let r = PitchLayout.apply(in: project, clipId: clipId, steps: plan.steps, truncated: plan.truncated) else { return false }
        guard edit(undo, { $0 = r.project }) else { return false }
        setSelection(ClipSelection(ids: Set(r.newIds + [clipId]), primary: clipId))
        var msg = "\(plan.steps.count) 個のクリップを並べました（\(what)）"
        if r.movedToOtherLayer { msg += "。元のレイヤーが塞がっていたので別のレイヤーに置きました" }
        if r.truncated > 0 { msg += "。音程が ±24 半音を超える \(r.truncated) 個は作りませんでした" }
        statusText = msg
        return true
    }
}
