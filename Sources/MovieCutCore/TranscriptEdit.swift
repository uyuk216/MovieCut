import Foundation

/// 文字起こしでテキスト編集: 選んだクリップの音声を文字にして、文(字幕 1 件分)の一覧を作る。
/// 一覧で外した文は、無音カットと同じ経路(`ClipEditing.removeSilence`)で取り除く。画面にも Undo にも依存しない。

/// 文 1 件。時刻はクリップの頭からの秒(クリップの長さの内側に収めてある)。
public struct TranscriptSentence: Equatable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double
    /// 単語ごとの時刻(クリップの頭からの秒。文の内側に収めてある)。
    /// 認識結果が単語の時刻を持つときだけ入る。持たない素材では空で、その文は単語単位では
    /// 編集できない(「文単位まで」が上限。推定で埋めることはしない)。
    /// `TranscriptSegment.words` と同じく、比較(`==`)には使わない。
    public var words: [TranscriptSegment] = []
    public init(text: String, start: Double, end: Double, words: [TranscriptSegment] = []) {
        self.text = text; self.start = start; self.end = end; self.words = words
    }
    public static func == (a: TranscriptSentence, b: TranscriptSentence) -> Bool {
        a.text == b.text && a.start == b.start && a.end == b.end
    }
    /// 単語単位の編集ができるか(単語の時刻があるか)。
    public var hasWordTiming: Bool { !words.isEmpty }
}

public enum TranscriptTextEdit {
    /// 単語の列を文にして、クリップの長さの内側に収める。本文が空・長さが 0 のものは捨てる。開始順。
    /// 文の切り方は字幕と同じ(`TranscriptGrouping.phrases`)。
    ///
    /// 単語の時刻の扱い(割り切り): 文の切り方は従来どおり入力の要素単位で決める
    /// (要素を単語へ展開してから組み直すことはしない。文の本文・開始・終了は、単語の
    /// 時刻が無い入力に対する従来の結果と完全一致する)。そのうえで、文を作った要素が
    /// すべて `words`(単語ごとの時刻)を持つときだけ、その単語の列を文へ引き継ぐ。
    /// `words` を持たない要素が 1 件でも混ざる文には単語の時刻を付けない(要素 1 件を
    /// 「1 単語」と言い換えるような推定も、文の一部だけに時刻を付けることもしない)。
    /// そのため、単語の時刻が取れない経路(Whisper のトークンが文字化けして文単位に
    /// 落とした場合など)では、文の `words` は空になり、単語単位の編集はできないことが
    /// 文ごとに分かる。
    public static func sentences(from segments: [TranscriptSegment], clip: Clip) -> [TranscriptSentence] {
        let dur = clip.duration
        guard dur > 0 else { return [] }
        // 要素 1 件 = 組み立ての単位 1 件。要素が持つ単語の列は、引き継ぎ用に別に持っておく
        // (`seg` 自体は phrases が作る「1 件分の単語」と同じ形に整えたもの)。
        struct Leaf { var seg: TranscriptSegment; var sourceWords: [TranscriptSegment] }
        // TranscriptGrouping.phrases と同じ条件で要素を整える(本文の前後の空白を取り、空・不正な時刻は捨てる)。
        // phrases は整えた要素を順に全部使うので、文の words の件数で要素の消費を数えられる。
        let usable: [Leaf] = segments.compactMap { s in
            let t = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, s.start.isFinite, s.end.isFinite else { return nil }
            return Leaf(seg: TranscriptSegment(text: t, start: s.start, end: max(s.start, s.end)),
                        sourceWords: s.words)
        }
        let phrases = TranscriptGrouping.phrases(from: usable.map(\.seg))
        var out: [TranscriptSentence] = []
        var cursor = 0   // usable の消費位置
        for p in phrases {
            let k = p.words.count
            let parts = usable[cursor..<min(cursor + k, usable.count)]
            cursor += k
            // 文を作った要素がすべて単語の時刻を持つときだけ、その単語の列を引き継ぐ。
            let allTimed = k > 0 && parts.count == k && parts.allSatisfy { !$0.sourceWords.isEmpty }
            let text = p.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, p.start.isFinite, p.end.isFinite else { continue }
            let a = min(max(0, p.start), dur)
            let b = min(max(a, p.end), dur)
            guard b - a > 1e-3 else { continue }
            var words: [TranscriptSegment] = []
            if allTimed {
                for w in parts.flatMap(\.sourceWords) {
                    let wt = w.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !wt.isEmpty, w.start.isFinite, w.end.isFinite else { continue }
                    let wa = min(max(0, w.start), dur)
                    let wb = min(max(wa, w.end), dur)
                    guard wb - wa > 1e-3 else { continue }
                    words.append(TranscriptSegment(text: wt, start: wa, end: wb))
                }
            }
            out.append(TranscriptSentence(text: text, start: a, end: b, words: words))
        }
        return out
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
