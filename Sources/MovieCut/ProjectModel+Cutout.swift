import AppKit
import MovieCutCore

/// 静止画の背景抜き: 前景マスクで透明な PNG を作り、クリップの素材をそれに差し替える(Undo は 1 回)。
/// 検出と書き出しは主スレッドの外で行う。保存先は Application Support/MovieCut/Cutouts。
extension ProjectModel {
    func removeBackgroundSelected() {
        guard !isLocked, let c = selectedClip, c.type == .image, let src = c.src else {
            statusText = "静止画のクリップを選んでください"
            return
        }
        let clipId = c.id
        statusText = "背景を抜いています…"
        Task.detached(priority: .userInitiated) {
            do {
                let image = try ForegroundCutout.readImage(at: URL(fileURLWithPath: src))
                let cut = try ForegroundCutout.cutout(image, detector: VisionForegroundDetector())
                let dir = CutoutDirectory.cutouts
                let dest = dir.appendingPathComponent("\(clipId)-\(UUID().uuidString.prefix(8)).png")
                try ForegroundCutout.writePNG(cut, to: dest)
                await self.applyCutout(clipId: clipId, path: dest.path)
            } catch {
                let message = (error as? ForegroundCutoutError) == .noForeground
                    ? "前景が見つかりませんでした(人物や物がはっきり写っている画像で試してください)"
                    : "背景を抜けませんでした: \(error.localizedDescription)"
                await MainActor.run { self.statusText = message }
            }
        }
    }

    /// 切り抜いた PNG をクリップの素材にする(1 回の Undo)。クリップが消えていたら何もしない。
    @MainActor
    func applyCutout(clipId: String, path: String) {
        var found = false
        _ = edit("背景を抜く") { p in
            for ti in p.tracks.indices {
                if let ci = p.tracks[ti].clips.firstIndex(where: { $0.id == clipId }) {
                    p.tracks[ti].clips[ci].src = path
                    found = true
                }
            }
        }
        statusText = found ? "背景を抜きました" : "クリップが見つからないため、差し替えませんでした"
    }
}

/// 切り抜き画像などの保存先(Application Support/MovieCut/...)。
enum CutoutDirectory {
    static var cutouts: URL {
        FontLibrary.defaultDirectory().deletingLastPathComponent().appendingPathComponent("Cutouts", isDirectory: true)
    }
}
