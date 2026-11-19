import Foundation
import AppKit
import UniformTypeIdentifiers
import MovieCutCore

/// 出力 ▸ 文字起こしを書き出す…(選んでいる音のあるクリップを音声認識し、txt か srt のファイルにする。字幕レイヤーにも載せられる)。
/// 認識・整形・時刻の変換は Core(`SubtitleTranscription.segments` / `TranscriptSubtitles` / `TranscriptText`)。
/// ここは進み・キャンセル・Undo(1 回)・状態欄・パネルだけ。
extension ProjectModel {
    static let transcriptExportUndoName = "文字起こしを書き出す"

    /// 選んでいるクリップを認識して `url` に書く。`addToTimeline` が true なら、書けた後で「字幕」レイヤーにも足す(Undo は 1 回)。
    /// 認識結果が空ならファイルは作らず false。キャンセルは状態欄に出して何も変えない。失敗は日本語のエラーを出す。
    @discardableResult
    func exportTranscriptOfSelectedClip(transcriber: Transcriber, to url: URL, format: TranscriptExportFormat, addToTimeline: Bool) async -> Bool {
        guard !isLocked else { return false }
        guard let c = selectedClip, TranscriptionSupport.supports(c) else {
            statusText = "音のあるクリップを選んでください(速度を変えたクリップ・逆再生は対象外)"
            return false
        }
        let snapshot = project
        let style = TextStyleLibrary.builtins.first { $0.id == "builtin.classic" }?.look
        busyMessage = "音声を文字にしています…"
        let job = Task { [weak self] in
            try await SubtitleTranscription.segments(clip: c, transcriber: transcriber,
                                                     onProgress: { [weak self] p in
                                                         Task { @MainActor in self?.busyMessage = "音声を文字にしています \(Int(p * 100))%" }
                                                     })
        }
        transcribeCancel = { job.cancel() }
        let outcome: Result<[TranscriptSegment], Error>
        do { outcome = .success(try await job.value) } catch { outcome = .failure(error) }
        transcribeCancel = nil
        busyMessage = nil

        let segments: [TranscriptSegment]
        switch outcome {
        case .success(let s):
            segments = s
            registerTranscript(for: c, segments: s)
        case .failure(let error):
            if error is CancellationError {
                statusText = "音声の認識をキャンセルしました"
            } else {
                errorTitle = "文字起こしを書き出せませんでした"
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            return false
        }

        let cues = TranscriptSubtitles.cues(from: segments, clip: c)
        guard !cues.isEmpty else {
            statusText = "認識できた文字がありませんでした。ファイルは作りませんでした"
            return false
        }
        do {
            try TranscriptText.string(for: format, cues: cues).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorTitle = "文字起こしを書き出せませんでした"
            errorMessage = error.localizedDescription
            return false
        }

        guard addToTimeline else {
            statusText = "文字起こし \(cues.count) 件を書き出しました: \(url.lastPathComponent)"
            return true
        }
        // 認識の間に編集が変わっていたら、字幕の追加だけ止める(書き出したファイルは残す)。
        guard project == snapshot else {
            statusText = "認識中に編集が変わったので、字幕は入れませんでした(ファイルは書き出しました: \(url.lastPathComponent))"
            return true
        }
        guard let made = SubtitleGeneration.appendCues(cues, to: project, style: style) else { return true }
        guard edit(Self.transcriptExportUndoName, { $0 = made.project }) else { return true }
        statusText = "文字起こし \(cues.count) 件を書き出し、字幕を \(made.count) 件入れました(1 回で元に戻せます)"
        return true
    }

    /// 出力 ▸ 文字起こしを書き出す…(Apple の音声認識)。
    func chooseAndExportTranscript() {
        chooseAndExportTranscript { SpeechFrameworkTranscriber() }
    }

    /// 出力 ▸ 文字起こしを書き出す（Whisper）…(外部の whisper.cpp。精度を上げたいとき)。
    func chooseAndExportTranscriptWithWhisper() {
        chooseAndExportTranscript { WhisperTranscriber() }
    }

    /// 先に保存先と形式(拡張子。知らない拡張子は txt)を決め、次に「タイムラインにも字幕を載せますか？」を聞いてから認識する。
    private func chooseAndExportTranscript(makeTranscriber: @escaping () -> Transcriber) {
        guard !isLocked else { return }
        guard selectedClip.map(TranscriptionSupport.supports) == true else {
            statusText = "音のあるクリップを選んでください(速度を変えたクリップ・逆再生は対象外)"
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "txt"), UTType(filenameExtension: "srt")].compactMap { $0 }
        panel.nameFieldStringValue = documentName + "-文字起こし.txt"
        panel.canCreateDirectories = true
        panel.title = L10n.t("文字起こしを書き出す")
        panel.message = L10n.t("拡張子 .txt(本文だけ)か .srt(時刻つき)で保存します")
        let run: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            guard resp == .OK, let url = panel.url, let self else { return }
            let format = TranscriptExportFormat(pathExtension: url.pathExtension) ?? .txt
            guard let addToTimeline = self.askAddTranscriptToTimeline() else { return }
            Task { @MainActor in
                await self.exportTranscriptOfSelectedClip(transcriber: makeTranscriber(), to: url, format: format, addToTimeline: addToTimeline)
            }
        }
        if let w = window { panel.beginSheetModal(for: w, completionHandler: run) } else { panel.begin(completionHandler: run) }
    }

    /// 字幕レイヤーにも載せるかを聞く。「載せて書き出す」→ true、「ファイルだけ書き出す」→ false、キャンセル → nil。
    private func askAddTranscriptToTimeline() -> Bool? {
        let alert = NSAlert()
        alert.messageText = L10n.t("文字起こしを書き出す")
        alert.informativeText = L10n.t("タイムラインにも字幕を載せますか?(字幕レイヤーに文字クリップとして入ります。1 回で元に戻せます)")
        alert.addButton(withTitle: L10n.t("載せて書き出す"))
        alert.addButton(withTitle: L10n.t("ファイルだけ書き出す"))
        alert.addButton(withTitle: L10n.t("キャンセル"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return true
        case .alertSecondButtonReturn: return false
        default: return nil
        }
    }
}
