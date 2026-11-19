import Foundation

/// 文字起こしの書き出し形式(txt は本文だけ、srt は既存の字幕ファイル形式)。
public enum TranscriptExportFormat: String, CaseIterable, Sendable {
    case txt, srt

    public var fileExtension: String { rawValue }

    /// 出力先の拡張子から決める(".TXT" も可。知らない拡張子は nil)。
    public init?(pathExtension: String) {
        self.init(rawValue: pathExtension.lowercased())
    }

    /// 既存の字幕形式との対応(srt のみ。txt は字幕形式ではないので nil)。
    public var subtitleFormat: SubtitleFormat? {
        switch self {
        case .srt: return .srt
        case .txt: return nil
        }
    }
}

/// 文字起こしのプレーンテキスト整形(画面にも Undo にも依存しない純粋な処理)。
public enum TranscriptText {
    /// 1件1行で改行連結し、末尾に改行を1つ付ける。空の件は捨てる。全部空なら空文字。
    /// 言語はいじらない(日英混在はそのまま残る)。
    public static func plainText(from segments: [TranscriptSegment]) -> String {
        join(segments.map(\.text))
    }

    public static func plainText(from cues: [SubtitleCue]) -> String {
        join(cues.map(\.text))
    }

    /// 形式に合わせた全文。txt は `plainText`、srt は `SubtitleFile.format` に任せる。
    public static func string(for format: TranscriptExportFormat, cues: [SubtitleCue]) -> String {
        switch format {
        case .txt: return plainText(from: cues)
        case .srt: return SubtitleFile.format(cues, as: .srt)
        }
    }

    private static func join(_ texts: [String]) -> String {
        let lines = texts
            .map { SubtitleFile.cleanBody($0).replacingOccurrences(of: "\n", with: " ") }
            .filter { !$0.isEmpty }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }
}

/// 文字誤り率(評価用の純粋関数)。
public enum CharacterErrorRate {
    /// 空白類を除き小文字にそろえ、文字単位の編集距離 ÷ 正解の文字数。
    /// 正解が空なら、認識も空で 0、そうでなければ 1。1 を超えることもある(挿入が多いとき)。
    public static func rate(reference: String, hypothesis: String) -> Double {
        let r = normalize(reference), h = normalize(hypothesis)
        if r.isEmpty { return h.isEmpty ? 0 : 1 }
        return Double(distance(r, h)) / Double(r.count)
    }

    private static func normalize(_ s: String) -> [String] {
        s.lowercased().filter { !$0.isWhitespace }.map { String($0) }
    }

    /// Levenshtein 距離(2行だけ持つ)。
    private static func distance(_ a: [String], _ b: [String]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }
}
