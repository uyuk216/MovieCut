import Foundation
import MovieCutCore

/// クリップ ▸ ビートにマーカーを打つ: 選んでいる音のクリップのビートに、マーカーを足す(1 回で Undo)。
extension ProjectModel {
    static let beatUndoName = "ビートにマーカー"

    /// 選んでいるクリップのビートを測ってマーカーを足す。測るのは別のタスク(画面を止めない)。
    /// 音が読めない・ビートが取れない・足すものが無いときは何もしない(Undo にも載せない)。
    func addBeatMarkersToSelectedClip() {
        guard !isLocked, let c = selectedClip, BeatDetector.supports(c) else { return }
        let clipId = c.id
        Task { [weak self] in
            let grid: BeatGrid? = await Task.detached(priority: .userInitiated) { () -> BeatGrid? in
                guard let prof = SilenceDetector.analyze(clip: c) else { return nil }
                return BeatDetector.analyze(profile: prof)
            }.value
            guard let self, let grid, let current = self.clip(clipId) else { return }
            _ = self.applyBeatMarkers(BeatDetector.projectTimes(grid, clip: current), bpm: grid.bpm)
        }
    }

    /// 足すビートの時刻(プロジェクトの時刻)をマーカーにする。1 回の Undo。足すものが無ければ false。
    @discardableResult
    func applyBeatMarkers(_ times: [Double], bpm: Double) -> Bool {
        guard !isLocked else { return false }
        let r = MarkerEditing.addBeats(in: project, times: times, tolerance: markerTolerance)
        guard r.added > 0 else {
            statusText = "ビートが見つかりませんでした"
            return false
        }
        let ok = edit(Self.beatUndoName) { $0 = r.project }
        if ok { statusText = String(format: "ビート %d 個にマーカーを打ちました（約 %.0f BPM）", r.added, bpm) }
        return ok
    }
}
