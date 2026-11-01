import Foundation

/// 文字起こしでテキスト編集: 選んだクリップの音声を文字にして、文(字幕 1 件分)の一覧を作る。
/// 一覧で外した文は、無音カットと同じ経路(`ClipEditing.removeSilence`)で取り除く。画面にも Undo にも依存しない。

/// 文 1 件。時刻はクリップの頭からの秒(クリップの長さの内側に収めてある)。
public struct TranscriptSentence: Equatable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double
    public init(text: String, start: Double, end: Double) { self.text = text; self.start = start; self.end = end }
}

public enum TranscriptTextEdit {
    /// 単語の列を文にして、クリップの長さの内側に収める。本文が空・長さが 0 のものは捨てる。開始順。
    /// 文の切り方は字幕と同じ(`TranscriptGrouping.phrases`)。
    public static func sentences(from words: [TranscriptSegment], clip: Clip) -> [TranscriptSentence] {
        let dur = clip.duration
        guard dur > 0 else { return [] }
        return TranscriptGrouping.phrases(from: words).compactMap { p in
            let text = p.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, p.start.isFinite, p.end.isFinite else { return nil }
            let a = min(max(0, p.start), dur)
            let b = min(max(a, p.end), dur)
            guard b - a > 1e-3 else { return nil }
            return TranscriptSentence(text: text, start: a, end: b)
        }
    }

    /// 選んだクリップの音声を文字にして、文の一覧を返す。キャンセルは `CancellationError`。一時ファイルは終わったら消す。
    public static func run(clip: Clip, transcriber: Transcriber,
                           tempDirectory: URL = FileManager.default.temporaryDirectory,
                           onProgress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> [TranscriptSentence] {
        guard TranscriptionSupport.supports(clip) else { return [] }
        let url = tempDirectory.appendingPathComponent("moviecut-textedit-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try await Task.detached(priority: .userInitiated) { try TranscriptionAudio.writeWAV(clip: clip, to: url) }.value
        try Task.checkCancellation()
        let words = try await transcriber.transcribe(audioURL: url, duration: clip.duration, onProgress: onProgress)
        try Task.checkCancellation()
        return sentences(from: words, clip: clip)
    }

    /// 外した文(取り除く文)を、カットの範囲に直す。
    public static func cuts(for removed: [TranscriptSentence]) -> [SilenceRange] {
        removed.map { SilenceRange(start: $0.start, end: $0.end) }
    }
}
