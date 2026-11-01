import Foundation
import MovieCutCore

/// メニュー ▸ クリップ ▸ 動きに追従させる。選んだ文字・図形・画像を、下のレイヤーの映像の中央の物体に合わせて動かす
/// (x・y のキーフレームを作る。1 回の Undo)。追跡(Vision・裏で実行)と計算は MovieCutCore(`MotionTrack`)。
extension ProjectModel {
    static let motionUndoName = "動きに追従させる"

    /// 追従できる(文字・図形・画像を選び、下に映像・画像のレイヤーがある)。
    func canTrackMotion(_ c: Clip) -> Bool {
        MotionTrack.canTrack(c) && MotionTrack.sourceClip(for: c.id, in: project) != nil
    }

    func trackMotionSelected() {
        guard !isLocked, let id = selectedClipId, let c = clip(id) else { return }
        guard let source = MotionTrack.sourceClip(for: id, in: project) else {
            errorTitle = "動きに追従できません"
            errorMessage = "文字・図形・画像を、映像・画像のレイヤーより上に置いてください。"
            return
        }
        let project = self.project
        let assets = self.assets
        let start = c.start, duration = c.duration
        Task { @MainActor [weak self] in
            // 追跡は重いので裏で行う(コマは 1 枚ずつ取り、Vision に渡す)
            let samples = await Task.detached(priority: .userInitiated) { () -> [CGRect?] in
                let renderer = Renderer(project: project, assets: assets)
                return MotionTrack.track(duration: duration, tracker: VisionRectTracker()) { t in
                    renderer.trackingFrame(of: source, at: start + t)
                }
            }.value
            guard let self, !self.isLocked, self.clip(id) != nil else { return }
            guard samples.contains(where: { $0 != nil }) else {
                self.errorTitle = "動きを追えませんでした"
                self.errorMessage = "下の映像の中央に、追いかけられる物体が見つかりませんでした。"
                return
            }
            _ = self.edit(Self.motionUndoName) { p in
                guard let loc = ClipEditing.locate(id, in: p) else { return }
                _ = MotionTrack.apply(samples: samples, to: &p.tracks[loc.track].clips[loc.index])
            }
        }
    }
}
