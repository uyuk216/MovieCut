import Foundation

/// 字幕の決まりごとの確認で見つけた問題 1 件。
public struct SubtitleIssue: Equatable, Sendable {
    public enum Kind: String, Sendable {
        /// 終わりが始まり以下(表示されない)。
        case invalidRange
        /// 本文が空。
        case emptyText
        /// 表示時間が短すぎる。
        case tooShort
        /// 表示時間が長すぎる。
        case tooLong
        /// 前の字幕と時刻が重なっている。
        case overlap
        /// 行数が多い。
        case tooManyLines
        /// 1 行が長い。
        case lineTooLong
        /// 文字数に対して表示時間が短い(読み切れない)。
        case readingTooFast
    }

    /// 確認した列の中での番号(0 から)。
    public let cueIndex: Int
    public let kind: Kind
    /// 人が読む説明(日本語)。
    public let message: String

    public init(cueIndex: Int, kind: Kind, message: String) {
        self.cueIndex = cueIndex; self.kind = kind; self.message = message
    }
}

/// 字幕の決まりごと(SRT/VTT で渡すときの目安)の確認。画面にも Undo にも依存しない純粋な処理。
/// あくまで目安の警告で、字幕そのものは直さない(直すかどうかは使う人が決める)。
/// しきい値は字幕の一般的な目安: 表示 0.8〜7 秒・2 行まで・1 行 25 字・1 秒 15 字まで。
public enum SubtitleValidator {
    public static let minDuration = 0.8
    public static let maxDuration = 7.0
    public static let maxLines = 2
    public static let maxLineLength = 25
    public static let maxCharsPerSecond = 15.0

    private static func sec(_ v: Double) -> String { String(format: "%.1f", v) }

    /// 字幕の列を確認する。返す問題は字幕の番号順(同じ字幕では種類名順)。
    public static func validate(_ cues: [SubtitleCue]) -> [SubtitleIssue] {
        var out: [SubtitleIssue] = []
        for (i, c) in cues.enumerated() {
            let body = c.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if body.isEmpty {
                out.append(SubtitleIssue(cueIndex: i, kind: .emptyText, message: "本文が空です"))
            }
            let dur = c.end - c.start
            guard dur > 0 else {
                out.append(SubtitleIssue(cueIndex: i, kind: .invalidRange, message: "終わりが始まり以下で、表示されません"))
                continue
            }
            if dur < minDuration {
                out.append(SubtitleIssue(cueIndex: i, kind: .tooShort, message: "表示が \(sec(dur)) 秒で短すぎます(目安 \(sec(minDuration)) 秒以上)"))
            }
            if dur > maxDuration {
                out.append(SubtitleIssue(cueIndex: i, kind: .tooLong, message: "表示が \(sec(dur)) 秒で長すぎます(目安 \(sec(maxDuration)) 秒まで)"))
            }
            if !body.isEmpty {
                let lines = body.components(separatedBy: "\n")
                if lines.count > maxLines {
                    out.append(SubtitleIssue(cueIndex: i, kind: .tooManyLines, message: "\(lines.count) 行あります(目安 \(maxLines) 行まで)"))
                }
                if let longest = lines.map(\.count).max(), longest > maxLineLength {
                    out.append(SubtitleIssue(cueIndex: i, kind: .lineTooLong, message: "1 行が \(longest) 字で長すぎます(目安 \(maxLineLength) 字まで)"))
                }
                let chars = body.filter { !$0.isNewline }.count
                let cps = Double(chars) / dur
                if cps > maxCharsPerSecond {
                    out.append(SubtitleIssue(cueIndex: i, kind: .readingTooFast, message: "1 秒あたり \(sec(cps)) 字で速すぎます(目安 \(sec(maxCharsPerSecond)) 字まで)"))
                }
            }
        }
        // 重なりは開始順に並べて隣同士で見る(報告は元の番号で)
        let order = cues.indices.sorted { (cues[$0].start, $0) < (cues[$1].start, $1) }
        for (a, b) in zip(order, order.dropFirst()) {
            if cues[b].start < cues[a].end - 1e-9, cues[a].end > cues[a].start {
                out.append(SubtitleIssue(cueIndex: b, kind: .overlap, message: "前の字幕と時刻が重なっています"))
            }
        }
        return out.sorted { ($0.cueIndex, $0.kind.rawValue) < ($1.cueIndex, $1.kind.rawValue) }
    }

    /// プロジェクトから書き出す字幕(`SubtitleFile.cues`)を確認する。
    public static func validate(project: Project) -> [SubtitleIssue] {
        validate(SubtitleFile.cues(from: project))
    }
}
