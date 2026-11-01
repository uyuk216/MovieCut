import Foundation
import MovieCutCore

/// メニュー ▸ クリップ ▸ 縦動画に自動リフレーム。被写体の検出(Vision・裏で実行)から計画を作り、
/// 出力を 1080×1920 に切り替えて、選んだクリップに x のキーフレームを入れる(1 回の Undo)。計算は MovieCutCore(`AutoReframe`)。
extension ProjectModel {
    static let autoReframeUndoName = "縦動画に自動リフレーム"
    static let portraitResolution = (w: 1080, h: 1920)

    /// 選んでいるのが映像・画像で、切り抜き(crop)が無いときだけ使える。
    func canAutoReframe(_ c: Clip) -> Bool {
        (c.type == .video || c.type == .image) && c.src != nil && (c.crop?.isEmpty ?? true)
    }

    func autoReframeSelected() {
        guard !isLocked, let id = selectedClipId, let c = clip(id), canAutoReframe(c) else { return }
        let project = self.project
        let assets = self.assets
        Task { @MainActor [weak self] in
            // 検出は重いので裏で行う(映像は 5/s でコマを取り、Vision で被写体を探す)
            let samples = await Task.detached(priority: .userInitiated) { () -> (w: Double, h: Double, list: [SubjectSample])? in
                Renderer(project: project, assets: assets).reframeSamples(of: c, detector: VisionSubjectDetector())
            }.value
            guard let self, !self.isLocked, self.clip(id) != nil else { return }
            guard let s = samples, let plan = AutoReframe.plan(samples: s.list, sourceWidth: s.w, sourceHeight: s.h) else {
                self.errorTitle = "縦動画にできません"
                self.errorMessage = "自動リフレームは、横長の映像・画像(16:9 など)で使えます。"
                return
            }
            self.applyAutoReframe(plan, clipId: id)
        }
    }

    /// 出力を 1080×1920 にして、クリップに計画を書く。解像度が変わるときは他のクリップも同じ道(`scaledForResolution`)で合わせる。1 回の Undo。
    func applyAutoReframe(_ plan: AutoReframe.Plan, clipId: String) {
        let (w, h) = Self.portraitResolution
        edit(Self.autoReframeUndoName) { p in
            if p.width != w || p.height != h {
                p = p.scaledForResolution(newWidth: w, newHeight: h)
                if !OutputPlan.h264Supports(width: w, height: h) { p.codec = "hevc" }
            }
            guard let loc = ClipEditing.locate(clipId, in: p) else { return }
            AutoReframe.apply(plan, to: &p.tracks[loc.track].clips[loc.index])
        }
    }
}
