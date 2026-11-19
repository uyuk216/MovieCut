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
    /// 単語の時刻の扱い(割り切り): 入力の各要素が `words`(単語ごとの時刻)を持つときだけ、
    /// その単語を本物の単語として文へ引き継ぐ。`words` を持たない要素は文そのものの単位と
    /// みなし、その要素からできた文には単語の時刻を付けない(要素 1 件を「1 単語」と
    /// 言い換えるような推定はしない)。そのため、単語の時刻が取れない経路
    /// (Whisper のトークンが文字化けして文単位に落とした場合など)では、文の `words` は
    /// 空になり、単語単位の編集はできないことが文ごとに分かる。
    public static func sentences(from segments: [TranscriptSegment], clip: Clip) -> [TranscriptSentence] {
        let dur = clip.duration
        guard dur > 0 else { return [] }
        // 葉へ展開する: words を持つ要素はその単語が葉(本物の単語)、持たない要素は要素自身が葉(単語ではない)。
        struct Leaf { var seg: TranscriptSegment; var isWord: Bool }
        var leaves: [Leaf] = []
        for s in segments {
            if s.words.isEmpty {
                leaves.append(Leaf(seg: s, isWord: false))
            } else {
                leaves.append(contentsOf: s.words.map { Leaf(seg: $0, isWord: true) })
            }
        }
        // TranscriptGrouping.phrases と同じ条件で葉を整える(本文の前後の空白を取り、空・不正な時刻は捨てる)。
        // phrases は整えた葉を順に全部使うので、文の words の件数で葉の消費を数えられる。
        let usable: [Leaf] = leaves.compactMap { leaf in
            let t = leaf.seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, leaf.seg.start.isFinite, leaf.seg.end.isFinite else { return nil }
            return Leaf(seg: TranscriptSegment(text: t, start: leaf.seg.start, end: max(leaf.seg.start, leaf.seg.end)),
                        isWord: leaf.isWord)
        }
        let phrases = TranscriptGrouping.phrases(from: usable.map(\.seg))
        var out: [TranscriptSentence] = []
        var cursor = 0   // usable の消費位置
        for p in phrases {
            let k = p.words.count
            let flags = usable[cursor..<min(cursor + k, usable.count)].map(\.isWord)
            cursor += k
            // 文を作った葉がすべて本物の単語のときだけ、単語の時刻を引き継ぐ。
            let allWords = k > 0 && flags.count == k && flags.allSatisfy { $0 }
            let text = p.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, p.start.isFinite, p.end.isFinite else { continue }
            let a = min(max(0, p.start), dur)
            let b = min(max(a, p.end), dur)
            guard b - a > 1e-3 else { continue }
            var words: [TranscriptSegment] = []
            if allWords {
                for w in p.words {
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
