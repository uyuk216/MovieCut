import Foundation
import MovieCutCore

/// クリップ ▸ 文字起こしで編集…: 音を文字にして文の一覧を出し、外した文を無音カットと同じ経路で取り除く。
/// 認識と区間は Core(`TranscriptTextEdit`)。ここは選択・Undo(1 回)・状態欄だけ。
extension ProjectModel {
    static let transcriptEditUndoName = "文字起こしで編集"

    /// 選んだクリップが音声認識の対象なら、シートを開く。
    func openTranscriptEditSheet() {
        guard !isLocked, let c = selectedClip, TranscriptionSupport.supports(c) else { return }
        transcriptEditClipId = c.id
        showTranscriptEditSheet = true
    }

    /// シートの読み込み: 認識して文の一覧を作る。キャンセルは `CancellationError`。
    func scanTranscriptSentences(transcriber: Transcriber = SpeechFrameworkTranscriber()) async throws -> [TranscriptSentence] {
        guard let id = transcriptEditClipId, let c = clip(id), TranscriptionSupport.supports(c) else { throw TranscriptionError.noAudio }
        return try await TranscriptTextEdit.run(clip: c, transcriber: transcriber)
    }

    /// 外した文を取り除く(全体で 1 回の Undo)。外した文が無い・切れないときは何もしない(false)。
    @discardableResult
    func cutTranscriptSentences(clipId: String, removed: [TranscriptSentence], ripple: Bool) -> Bool {
        guard !isLocked, !removed.isEmpty else { return false }
        guard let r = ClipEditing.removeSilence(in: project, clipId: clipId, cuts: TranscriptTextEdit.cuts(for: removed), ripple: ripple) else {
            statusText = "文字起こしで編集できませんでした(全部の文を外すと、クリップを切れません)"
            return false
        }
        guard edit(Self.transcriptEditUndoName, { $0 = r.project }) else { return false }
        selectedClipId = r.clipIds.first
        statusText = "文を \(removed.count) 件取り除きました(1 回で元に戻せます)"
        return true
    }
}
