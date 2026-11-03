import Foundation
import MovieCutCore

/// 出力 ▸ 音声から字幕を作る(選んでいる音のあるクリップを、オンデバイスの音声認識で文字にする)。
/// 認識と配置は Core(`SubtitleTranscription`)。ここは進み・キャンセル・Undo(1 回)・状態欄だけ。
extension ProjectModel {
    static let transcribeUndoName = "音声から字幕を作る"

    /// 選んでいるクリップを文字にして「字幕」レイヤーに足す。Undo は 1 回。認識結果が無ければ何も変えない。
    /// キャンセルは状態欄に出して何も変えない。失敗(許可なし・利用不可など)は日本語のエラーを出す。
    @discardableResult
    func transcribeSelectedToSubtitles(transcriber: Transcriber = SpeechFrameworkTranscriber()) async -> Bool {
        guard !isLocked else { return false }
        guard let c = selectedClip, TranscriptionSupport.supports(c) else {
            statusText = "音のあるクリップを選んでください(速度を変えたクリップ・逆再生は対象外)"
            return false
        }
        let snapshot = project
        let style = TextStyleLibrary.builtins.first { $0.id == "builtin.classic" }?.look
        busyMessage = "音声を文字にしています…"
        let job = Task { [weak self] in
            try await SubtitleTranscription.run(clip: c, project: snapshot, transcriber: transcriber, style: style,
                                                onProgress: { [weak self] p in
                                                    Task { @MainActor in self?.busyMessage = "音声を文字にしています \(Int(p * 100))%" }
                                                })
        }
        transcribeCancel = { job.cancel() }
        let outcome: Result<SubtitleGeneration.Result?, Error>
        do { outcome = .success(try await job.value) } catch { outcome = .failure(error) }
        transcribeCancel = nil
        busyMessage = nil

        switch outcome {
        case .success(let made?):
            guard project == snapshot else {
                statusText = "認識中に編集が変わったので、字幕は入れませんでした"
                return false
            }
            guard edit(Self.transcribeUndoName, { $0 = made.project }) else { return false }
            statusText = "音声から字幕を \(made.count) 件作りました(「字幕」レイヤー。1 回で元に戻せます)"
            return true
        case .success(nil):
            statusText = "認識できた文字がありませんでした。字幕は作りませんでした"
            return false
        case .failure(let error):
            if error is CancellationError {
                statusText = "音声の認識をキャンセルしました"
            } else {
                errorTitle = "音声から字幕を作れませんでした"
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            return false
        }
    }
}
