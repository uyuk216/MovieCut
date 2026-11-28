import Foundation
import MovieCutCore

/// 台本(文字起こし)とタイムラインの双方向編集。計算は Core(`TranscriptScripting`)。
/// ここは Undo(操作 1 回 = Undo 1 回。台本とクリップは同じ `Project` なので 1 つのスナップショットで戻る)・
/// 選択・状態欄だけ。台本ビューの表示は `project` から毎回再計算するので、タイムライン側の操作(分割・削除・移動・
/// Undo / Redo)もそのまま追随する。
extension ProjectModel {
    static let scriptEditUndoName = "台本で編集"

    /// 選んだクリップを、認識した文の頭で切り分けて台本と連動させる(1 回の Undo)。
    @discardableResult
    func linkTranscriptScript(clipId: String, sentences: [TranscriptSentence]) -> Bool {
        guard !isLocked else { return false }
        guard let r = TranscriptScripting.link(in: project, clipId: clipId, sentences: sentences) else {
            statusText = "台本と連動できませんでした(速度変更・逆再生・速度ランプのクリップ、ロック中、同じ素材の台本が既にある等)"
            return false
        }
        guard edit(Self.scriptEditUndoName, { $0 = r.project }) else { return false }
        statusText = "台本と連動しました(文 \(sentences.count) 件。1 回で元に戻せます)"
        return true
    }

    /// 台本の文を削除する: 対応するクリップをタイムラインから取り除く(文は「対応なし」として台本に残る)。
    @discardableResult
    func deleteScriptSentence(scriptId: String, sentenceId: String, ripple: Bool = true) -> Bool {
        guard !isLocked else { return false }
        guard let p = TranscriptScripting.deleteSentence(in: project, scriptId: scriptId, sentenceId: sentenceId, ripple: ripple),
              edit(Self.scriptEditUndoName, { $0 = p }) else {
            statusText = "文を削除できませんでした(対応するクリップが無い・ロックされている)"
            return false
        }
        statusText = "文を削除しました(タイムラインからも取り除きました。1 回で元に戻せます)"
        return true
    }

    /// 台本の行を並べ替える(`List.onMove` と同じ指定)。対応クリップがタイムライン上で台本の順に並び直る。
    @discardableResult
    func reorderScriptSentences(scriptId: String, fromOffsets: IndexSet, toOffset: Int) -> Bool {
        guard !isLocked else { return false }
        guard let p = TranscriptScripting.reorder(in: project, scriptId: scriptId, fromOffsets: fromOffsets, toOffset: toOffset),
              edit(Self.scriptEditUndoName, { $0 = p }) else {
            statusText = "並べ替えできませんでした(ほかのクリップと重なる・ロックされている)"
            return false
        }
        statusText = "文を並べ替えました(タイムラインも並べ替えました。1 回で元に戻せます)"
        return true
    }

    /// 対応なしの文をタイムラインへ戻す。
    @discardableResult
    func restoreScriptSentence(scriptId: String, sentenceId: String) -> Bool {
        guard !isLocked else { return false }
        guard let p = TranscriptScripting.restoreSentence(in: project, scriptId: scriptId, sentenceId: sentenceId),
              edit(Self.scriptEditUndoName, { $0 = p }) else {
            statusText = "文を戻せませんでした(ほかのクリップと重なる・ロックされている)"
            return false
        }
        statusText = "文をタイムラインへ戻しました(1 回で元に戻せます)"
        return true
    }

    /// 台本の文字を打ち直す(誤認識の修正)。台本の文字だけが変わる(音声・タイムラインは変わらない)。
    @discardableResult
    func retextScriptSentence(scriptId: String, sentenceId: String, text: String) -> Bool {
        guard !isLocked else { return false }
        guard let p = TranscriptScripting.retext(in: project, scriptId: scriptId, sentenceId: sentenceId, text: text),
              edit(Self.scriptEditUndoName, { $0 = p }) else { return false }
        statusText = "台本の文字を打ち直しました(音声は変わりません)"
        return true
    }

    /// 連動をやめる(台本とクリップの印を消す。クリップは変えない)。
    @discardableResult
    func unlinkTranscriptScript(scriptId: String) -> Bool {
        guard !isLocked, let p = TranscriptScripting.unlink(in: project, scriptId: scriptId),
              edit(Self.scriptEditUndoName, { $0 = p }) else { return false }
        statusText = "台本との連動をやめました(クリップはそのまま)"
        return true
    }
}
