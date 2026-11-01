import Foundation
import MovieCutCore

/// クリップ ▸ フィラー語をカット…: 音を文字にして見つかったフィラー語を一覧し、選んだものを無音カットと同じ経路で切る。
/// 認識と区間の求め方は Core(`FillerDetector`)。ここは選択・Undo(1 回)・状態欄だけ。
extension ProjectModel {
    static let fillerUndoName = "フィラー語をカット"

    /// 選んだクリップが音声認識の対象なら、シートを開く。
    func openFillerSheet() {
        guard !isLocked, let c = selectedClip, TranscriptionSupport.supports(c) else { return }
        fillerClipId = c.id
        showFillerSheet = true
    }

    /// シートの読み込み: 認識してフィラー語の区間を求める(クリップの頭からの秒)。キャンセルは `CancellationError`。
    func scanFillers(transcriber: Transcriber = SpeechFrameworkTranscriber()) async throws -> [FillerRange] {
        guard let id = fillerClipId, let c = clip(id), TranscriptionSupport.supports(c) else { throw TranscriptionError.noAudio }
        return try await FillerDetector.run(clip: c, transcriber: transcriber)
    }

    /// 選んだ区間をカットする(全体で 1 回の Undo)。区間が無い・切れないときは何もしない(false)。
    @discardableResult
    func cutFillers(clipId: String, ranges: [FillerRange], ripple: Bool) -> Bool {
        guard !isLocked, !ranges.isEmpty else { return false }
        guard let r = ClipEditing.removeSilence(in: project, clipId: clipId, cuts: FillerDetector.cuts(ranges), ripple: ripple) else {
            statusText = "フィラー語を切れませんでした(クリップの全部が語になるときは切れません)"
            return false
        }
        guard edit(Self.fillerUndoName, { $0 = r.project }) else { return false }
        selectedClipId = r.clipIds.first
        statusText = "フィラー語を \(ranges.count) 箇所カットしました(1 回で元に戻せます)"
        return true
    }
}
