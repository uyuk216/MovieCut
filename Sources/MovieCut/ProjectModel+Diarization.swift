import Foundation
import MovieCutCore

/// 話者分離(W3-27 / 監査 #75)の画面側の流れ。
/// 認識・特徴抽出・クラスタリングは Core(`DiarizationPipeline` / `AcousticClusterDiarizer`)。
/// ここはシート開閉と、字幕・台本への反映(Undo 1 回)だけを持つ。
/// 方式は音響特徴による簡易判定で、学習型の本格分離ではない(限界はシートと docs に明示)。
extension ProjectModel {
    static let diarizationSubtitleUndoName = "話者分離の字幕を作る"
    static let diarizationLabelUndoName = "話者ラベルを字幕に付ける"

    /// クリップ ▸ 話者分離…: 選んでいる音のあるクリップを対象にシートを開く。
    func openDiarizationSheet() {
        guard !isLocked, let c = selectedClip, TranscriptionSupport.supports(c) else {
            statusText = "音のあるクリップを選んでください(速度を変えたクリップ・逆再生は対象外)"
            return
        }
        diarizationClipId = c.id
        showDiarizationSheet = true
    }

    /// シートの読み込み: 認識して話者ラベルまで付けた結果を返す。キャンセルは `CancellationError`。
    func runDiarization(transcriber: Transcriber = SpeechFrameworkTranscriber(), maxSpeakers: Int = 4) async throws -> DiarizationPipeline.Run {
        guard let id = diarizationClipId, let c = clip(id), TranscriptionSupport.supports(c) else {
            throw TranscriptionError.noAudio
        }
        return try await DiarizationPipeline.run(clip: c, transcriber: transcriber, options: DiarizationOptions(maxSpeakers: maxSpeakers))
    }

    /// 話者ラベルつきの字幕を「字幕」レイヤーに作る(Undo 1 回)。認識結果が無ければ何も変えない。
    @discardableResult
    func applyDiarizationToSubtitles(_ diarized: [DiarizedSegment]) -> Bool {
        guard !isLocked, let id = diarizationClipId, let c = clip(id) else { return false }
        let cues = DiarizationApply.cues(from: diarized, clip: c)
        let style = TextStyleLibrary.builtins.first { $0.id == "builtin.classic" }?.look
        guard let made = SubtitleGeneration.appendCues(cues, to: project, style: style) else {
            statusText = "字幕にできる区間がありませんでした"
            return false
        }
        guard edit(Self.diarizationSubtitleUndoName, { $0 = made.project }) else { return false }
        statusText = "話者ラベルつき字幕を \(made.count) 件作りました(1 回で元に戻せます)"
        return true
    }

    /// 既にある文字クリップ(字幕)へ話者ラベルを付ける(Undo 1 回)。付けた件数を返す。
    @discardableResult
    func applyDiarizationLabelsToExistingSubtitles(_ diarized: [DiarizedSegment]) -> Int {
        guard !isLocked, let id = diarizationClipId, let c = clip(id) else { return 0 }
        var count = 0
        let ok = edit(Self.diarizationLabelUndoName) { p in
            count = DiarizationApply.applyToTextClips(diarized, clipStart: c.start, to: &p)
        }
        if ok && count > 0 {
            statusText = "字幕 \(count) 件に話者ラベルを付けました(1 回で元に戻せます)"
        } else if ok {
            statusText = "ラベルを付けられる字幕がありませんでした(時刻と文が合う文字クリップが対象です)"
        }
        return ok ? count : 0
    }

    /// 話者ラベルつきの行を台本欄へ送る(Undo 1 回)。送った行数を返す。
    @discardableResult
    func sendDiarizationToScript(_ diarized: [DiarizedSegment]) -> Int {
        appendScriptLinesWithUndo(DiarizationApply.scriptLines(from: diarized), name: "話者分離を台本へ送る")
    }
}
