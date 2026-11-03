import Foundation
import MovieCutCore

/// クリップ ▸ 音声で映像と音声を自動同期: 選んだ動画と音声の音を比べて、音声クリップの開始位置を動かす(1 回で Undo)。
extension ProjectModel {
    static let audioSyncUndoName = "音声で自動同期"

    /// 2 つのクリップの音を読んで合わせる。読むのは別のタスク(画面を止めない)。条件に合わなければ何もしない。
    func autoSyncSelectedClips() {
        guard !isLocked, let pair = AudioSyncEditing.pair(in: project, ids: selectedClipIDs) else { return }
        let v = pair.video, a = pair.audio
        statusText = "音を比べています…"
        Task { [weak self] in
            let lag: Double? = await Task.detached(priority: .userInitiated) { () -> Double? in
                guard let pv = SilenceDetector.analyze(clip: v), let pa = SilenceDetector.analyze(clip: a) else { return nil }
                return AudioSyncEditing.lagSeconds(video: AudioSyncEditing.envelope(from: pv), audio: AudioSyncEditing.envelope(from: pa))
            }.value
            guard let self else { return }
            guard let lag else { self.statusText = "音が一致せず、合わせられませんでした"; return }
            self.applyAudioSync(videoId: v.id, audioId: a.id, lag: lag)
        }
    }

    /// 求めたずれを音声クリップの開始位置に反映する。1 回の Undo。動かさなかったときは false(履歴に載せない)。
    @discardableResult
    func applyAudioSync(videoId: String, audioId: String, lag: Double) -> Bool {
        guard !isLocked else { return false }
        switch AudioSyncEditing.apply(to: project, videoId: videoId, audioId: audioId, lag: lag) {
        case .moved(let p, let s):
            let ok = edit(Self.audioSyncUndoName) { $0 = p }
            if ok { statusText = String(format: "音声を %.2f 秒に動かして合わせました", s) }
            return ok
        case .alreadySynced: statusText = "すでに合っています"
        case .beforeZero: statusText = "合わせると音声の頭が 0 秒より前になるため、動かしませんでした"
        case .locked: statusText = Self.lockedNotice
        case .invalid: statusText = "動画と音声のクリップが見つかりません"
        }
        return false
    }
}
