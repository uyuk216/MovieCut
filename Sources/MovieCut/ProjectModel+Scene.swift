import Foundation
import MovieCutCore

/// シーン境界での分割(メニュー・シートが呼ぶ)。検出と分割は MovieCutCore に任せ、
/// ここは Undo(1 操作 = 1 回)・選択・状態表示だけ。何も変わらない操作は Undo に積まない。
extension ProjectModel {
    /// 「シーンで分割…」のシートを開く(動画クリップを選んでいるときだけ)。
    func openSceneSheet() {
        guard !isLocked, let c = selectedClip, SceneDetector.supports(c) else { return }
        sceneClipId = c.id
        showSceneSheet = true
    }

    /// シートの決定: 測った差としきい値からカット点を求めて割る。全体で 1 回の Undo。割る所が無ければ false。
    @discardableResult
    func splitAtScenes(clipId: String, profile: SceneProfile, params: SceneParams) -> Bool {
        guard !isLocked else { return false }
        let cuts = profile.cutPoints(params)
        guard !cuts.isEmpty, let r = SceneDetector.splitAtScenes(in: project, clipId: clipId, cuts: cuts) else { return false }
        guard edit("シーンで分割", { $0 = r.project }) else { return false }
        selectedClipId = r.clipIds.first
        statusText = "\(cuts.count) 箇所のシーンで分割しました"
        return true
    }
}
