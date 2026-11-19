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
        let sentences = try await TranscriptTextEdit.run(clip: c, transcriber: transcriber)
        registerTranscript(for: c, segments: sentences.map { TranscriptSegment(text: $0.text, start: $0.start, end: $0.end, words: $0.words) })
        return sentences
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
    /// 選んだ単語を取り除く(全体で 1 回の Undo)。文の取り除きと同じ Undo 名・同じ経路。
    /// 単語の時刻が無い文の単語が混ざっていたら、何も変えず false にして、状態欄で
    /// 「単語単位の時刻が無いため文単位まで」を明示する(推定で文に広げることはしない)。
    /// 選択が空・切れないときも何もしない(false)。
    @discardableResult
    func cutTranscriptWords(clipId: String, sentences: [TranscriptSentence],
                            selections: Set<TranscriptWordEdit.Selection>, ripple: Bool) -> Bool {
        guard !isLocked, !selections.isEmpty else { return false }
        let touchesWordless = selections.contains { sel in
            sentences.indices.contains(sel.sentence) && !sentences[sel.sentence].hasWordTiming
        }
        if touchesWordless {
            statusText = "この素材は単語単位の時刻が無いため、単語単位では編集できません(文単位までです)"
            return false
        }
        guard let r = TranscriptWordEdit.removeWords(in: project, clipId: clipId, sentences: sentences,
                                                     selections: selections, ripple: ripple) else {
            statusText = "単語を取り除けませんでした(全部の単語を外すと、クリップを切れません)"
            return false
        }
        guard edit(Self.transcriptEditUndoName, { $0 = r.project }) else { return false }
        selectedClipId = r.clipIds.first
        statusText = "単語を \(selections.count) 件取り除きました(1 回で元に戻せます)"
        return true
    }
}
