import Foundation

/// フィラー語(えー・あー・えっと など)の区間。時刻はクリップの頭からの秒(認識の時刻と同じ)。
public struct FillerRange: Equatable, Sendable {
    /// 見つけた語(空白と句読点を除いた形)。
    public var text: String
    public var start: Double
    public var end: Double
    public init(text: String, start: Double, end: Double) { self.text = text; self.start = start; self.end = end }
}

/// フィラー語の区間を、認識の単語の時刻から探す(画面にも Undo にも依存しない)。
/// 単語が割れていても(「え」「ー」のように)、隣り合う単語が `maxGap` 以内に続けば連結して語と比べる。
/// 語の一致は、空白・句読点を除いた形どうしの完全一致。見つけた区間は重ならない。
public enum FillerDetector {
    /// 既定の語。「あの」「その」は普通の語でもあるので、シートで一覧を見てからカットする。
    public static let defaultFillers = ["えー", "あー", "えーと", "えっと", "ええと", "あのー", "あの", "その", "うーん"]

    /// 連結できる単語の最大の数(語の長さの上限は、語の中で一番長いものの文字数で決める)。
    static let maxTokens = 4
    static let punctuation: Set<Swift.Character> = ["、", "。", ",", ".", "！", "？", "!", "?", "「", "」", "『", "』", "・", "…", "-"]   // 長音記号「ー」は語の一部なので除かない

    /// 空白と句読点を除く。
    static func normalize(_ s: String) -> String {
        String(s.filter { !$0.isWhitespace && !punctuation.contains($0) })
    }

    /// 単語の列から、フィラー語の区間を開始順に返す。
    public static func find(in words: [TranscriptSegment], fillers: [String] = defaultFillers, maxGap: Double = TranscriptGrouping.maxGap) -> [FillerRange] {
        let set = Set(fillers.map(normalize).filter { !$0.isEmpty })
        guard let longest = set.map(\.count).max() else { return [] }
        let tokens = words
            .filter { $0.start.isFinite && $0.end.isFinite && !normalize($0.text).isEmpty }
            .sorted { $0.start < $1.start }
        var out: [FillerRange] = []
        var i = 0
        while i < tokens.count {
            var acc = ""
            var hit: (last: Int, text: String)?
            for j in i..<min(tokens.count, i + maxTokens) {
                if j > i, tokens[j].start - tokens[j - 1].end > maxGap { break }
                acc += normalize(tokens[j].text)
                if acc.count > longest { break }
                if set.contains(acc) { hit = (j, acc) }
            }
            if let h = hit {
                out.append(FillerRange(text: h.text, start: tokens[i].start, end: max(tokens[i].end, tokens[h.last].end)))
                i = h.last + 1
            } else {
                i += 1
            }
        }
        return out
    }

    /// 見つけた区間を、カットの範囲(`ClipEditing.removeSilence` に渡す形)に直す。
    public static func cuts(_ ranges: [FillerRange]) -> [SilenceRange] {
        ranges.map { SilenceRange(start: $0.start, end: $0.end) }
    }

    /// 選んだクリップの音声を文字にして、フィラー語の区間を探す。キャンセルは `CancellationError`。一時ファイルは終わったら消す。
    public static func run(clip: Clip, transcriber: Transcriber, fillers: [String] = defaultFillers,
                           tempDirectory: URL = FileManager.default.temporaryDirectory,
                           onProgress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> [FillerRange] {
        guard TranscriptionSupport.supports(clip) else { return [] }
        let url = tempDirectory.appendingPathComponent("moviecut-filler-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try await Task.detached(priority: .userInitiated) { try TranscriptionAudio.writeWAV(clip: clip, to: url) }.value
        try Task.checkCancellation()
        let words = try await transcriber.transcribe(audioURL: url, duration: clip.duration, onProgress: onProgress)
        try Task.checkCancellation()
        return find(in: words, fillers: fillers)
    }
}
