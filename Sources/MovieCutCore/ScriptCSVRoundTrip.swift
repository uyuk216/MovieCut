import Foundation

// MARK: - 台本 CSV の読み書き(往復対応 #42)
//
// 仕様の正は `docs/台本CSVとアイテムテンプレート.md`。要点:
// - 列は「キャラ,セリフ,読み,字幕,表情」の 5 列。書き出しは常に見出し行つき・UTF-8 BOM・CRLF・RFC 4180 の引用符。
// - セリフ = 元の表記(観客が読む文)、読み = 読み上げ文(かな等。空ならセリフをそのまま読む)、
//   字幕 = 表示文(空ならセリフと同じ。`""` と引用符で囲んだ空は「字幕なし」)、表情 = 表情タグ名(角括弧なし)。
// - 読み込みは見出しの列名でも位置でも読める。見出しが無い 3 列は従来形式(名前,読み上げ文,字幕文)として読む
//   (既存の `ScriptCSV.lines(fromCSV:)` と同じ結果になる)。1 列だけならセリフだけの台本。
// - ボイスクリップとの対応: 読み上げ文(`Clip.text` の本文) = 読み(無ければセリフ)、
//   `Clip.subtitleText` = 字幕(指定があればそれ、無くて読みがセリフと違えばセリフ、そうでなければ nil)。
//   この対応により、書き出し → 読み込みでクリップの内容が保たれる(往復テストで担保)。

extension ScriptCSV {
    /// 台本 CSV の 1 行。
    public struct Row: Equatable, Sendable {
        /// キャラ名(空 = 名前なし)。
        public var characterName: String
        /// セリフ(元の表記)。
        public var dialogue: String
        /// 読み(読み上げ文の上書き。空 = セリフと同じ)。
        public var reading: String
        /// 字幕文。nil = 指定なし、空文字 = 字幕なし、それ以外 = その文。
        public var subtitle: String?
        /// 表情タグ名(角括弧なし。空 = タグなし)。
        public var expression: String

        public init(characterName: String = "", dialogue: String, reading: String = "",
                    subtitle: String? = nil, expression: String = "") {
            self.characterName = characterName; self.dialogue = dialogue
            self.reading = reading; self.subtitle = subtitle; self.expression = expression
        }

        /// メモ行(先頭が ※)か。メモ行はセリフ欄にメモそのものが入る。
        public var isNote: Bool {
            characterName.isEmpty && reading.isEmpty && subtitle == nil && expression.isEmpty
                && dialogue.hasPrefix("※")
        }

        /// 実際に読み上げる文(表情タグを含む、`Clip.text` の形)。
        public var spokenText: String {
            let body = reading.isEmpty ? dialogue : reading
            return expression.isEmpty ? body : "[\(expression)]" + body
        }

        /// `Clip.subtitleText` に対応する値(台本の行・クリップ化で使う字幕文)。
        public var clipSubtitleText: String? {
            if let subtitle { return subtitle }
            if !reading.isEmpty && reading != dialogue { return dialogue }
            return nil
        }

        /// 台本テキストの 1 行(「名前: 読み上げ文 | 字幕文」。メモ行はそのまま)。
        public var scriptLine: String {
            if isNote { return dialogue }
            var line = characterName.isEmpty ? spokenText : "\(characterName): \(spokenText)"
            if let sub = clipSubtitleText {
                line += sub.isEmpty ? " |" : " | \(sub)"
            }
            return line
        }
    }

    /// 書き出しの見出し行。
    public static let exportHeader = ["キャラ", "セリフ", "読み", "字幕", "表情"]

    // MARK: 読み込み

    private struct Cell {
        var value: String
        var wasQuoted: Bool
    }

    /// 引用符で囲まれたかを残す分解(`rows(fromCSV:)` と同じ規則。字幕の「指定なし」と「字幕なし」を区別するため)。
    private static func parseCells(_ text: String) -> [[Cell]] {
        var rows: [[Cell]] = []
        var row: [Cell] = []
        var cell = ""
        var inQuotes = false
        var quoted = false
        let scalars = Array(text.unicodeScalars)
        var i = 0
        func endCell() { row.append(Cell(value: cell, wasQuoted: quoted)); cell = ""; quoted = false }
        func endRow() { endCell(); rows.append(row); row = [] }
        while i < scalars.count {
            let ch = scalars[i]
            if inQuotes {
                if ch == "\"" {
                    if i + 1 < scalars.count, scalars[i + 1] == "\"" { cell.unicodeScalars.append("\""); i += 2 }
                    else { inQuotes = false; i += 1 }
                } else { cell.unicodeScalars.append(ch); i += 1 }
                continue
            }
            switch ch {
            case "\"" where cell.isEmpty && !quoted:
                inQuotes = true; quoted = true; i += 1
            case ",": endCell(); i += 1
            case "\r": endRow(); i += (i + 1 < scalars.count && scalars[i + 1] == "\n") ? 2 : 1
            case "\n": endRow(); i += 1
            default: cell.unicodeScalars.append(ch); i += 1
            }
        }
        if !cell.isEmpty || !row.isEmpty || quoted { endRow() }
        return rows
    }

    static let dialogueHeaders: Set<String> = ["セリフ", "台詞", "本文"]
    static let readingHeaders: Set<String> = ["読み", "読み上げ", "読み上げ文", "発音", "よみ"]
    static let expressionHeaders: Set<String> = ["表情", "表情名"]

    /// CSV のテキストを行の一覧に直す。
    public static func scriptRows(fromCSV text: String) -> [Row] {
        let text = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        var rows = parseCells(text)
        guard !rows.isEmpty else { return [] }

        let nameHeadersAll = nameHeaders.union(["キャラ"])
        var nameIdx: Int?, dialogueIdx: Int?, readingIdx: Int?, subtitleIdx: Int?, expressionIdx: Int?
        var hasHeader = false
        if let h = rows.first?.map({ $0.value.trimmingCharacters(in: .whitespaces) }),
           h.contains(where: { nameHeadersAll.contains($0) || dialogueHeaders.contains($0) || readingHeaders.contains($0) || subtitleHeaders.contains($0) || expressionHeaders.contains($0) }),
           h.contains(where: { dialogueHeaders.contains($0) || readingHeaders.contains($0) || subtitleHeaders.contains($0) }) {
            hasHeader = true
            nameIdx = h.firstIndex(where: { nameHeadersAll.contains($0) })
            let d = h.firstIndex(where: { dialogueHeaders.contains($0) })
            let r = h.firstIndex(where: { readingHeaders.contains($0) })
            if let d { dialogueIdx = d; readingIdx = (r != nil && r != d) ? r : nil }
            else if let r { dialogueIdx = r; readingIdx = nil }
            subtitleIdx = h.firstIndex(where: { subtitleHeaders.contains($0) })
            expressionIdx = h.firstIndex(where: { expressionHeaders.contains($0) })
            rows.removeFirst()
        }

        var out: [Row] = []
        for rawRow in rows {
            let cells = rawRow.map { Cell(value: $0.value.trimmingCharacters(in: .whitespaces), wasQuoted: $0.wasQuoted) }
            if cells.allSatisfy({ $0.value.isEmpty }) { continue }
            if let note = cells.first(where: { !$0.value.isEmpty }), note.value.hasPrefix("※") {
                out.append(Row(dialogue: note.value))
                continue
            }
            // 見出しが無いときは列数で対応づける(3 列は従来形式 = 読み上げ文がセリフ欄)
            var nI = nameIdx, dI = dialogueIdx, rI = readingIdx, sI = subtitleIdx, eI = expressionIdx
            if !hasHeader {
                switch cells.count {
                case 1: nI = nil; dI = 0; rI = nil; sI = nil; eI = nil
                case 2: nI = 0; dI = 1; rI = nil; sI = nil; eI = nil
                case 3: nI = 0; dI = 1; rI = nil; sI = 2; eI = nil
                case 4: nI = 0; dI = 1; rI = 2; sI = 3; eI = nil
                default: nI = 0; dI = 1; rI = 2; sI = 3; eI = 4
                }
            }
            func value(_ idx: Int?) -> String {
                guard let idx, idx < cells.count else { return "" }
                return cells[idx].value
            }
            let dialogue = value(dI)
            guard !dialogue.isEmpty else { continue }
            var subtitle: String?
            if let sI, sI < cells.count {
                let c = cells[sI]
                subtitle = c.value.isEmpty ? (c.wasQuoted ? "" : nil) : c.value
            }
            var expression = value(eI)
            if expression.hasPrefix("["), expression.hasSuffix("]"), expression.count >= 2 {
                expression = String(expression.dropFirst().dropLast())
            }
            out.append(Row(characterName: value(nI), dialogue: dialogue, reading: value(rI),
                           subtitle: subtitle, expression: expression))
        }
        return out
    }

    /// 行の一覧を台本テキストの行に直す。
    public static func lines(fromRows rows: [Row]) -> [String] { rows.map(\.scriptLine) }

    // MARK: 書き出し

    /// 行の一覧を CSV にする(見出し行つき・BOM・CRLF)。メモ行は 1 セルだけ書く。
    public static func csv(from rows: [Row]) -> String {
        var lines: [String] = [exportHeader.map(csvCell).joined(separator: ",")]
        for row in rows {
            if row.isNote {
                lines.append(csvCell(row.dialogue))
                continue
            }
            let subtitleCell: String
            if let sub = row.subtitle {
                subtitleCell = sub.isEmpty ? "\"\"" : csvCell(sub)
            } else { subtitleCell = "" }
            let cells = [csvCell(row.characterName), csvCell(row.dialogue), csvCell(row.reading),
                         subtitleCell, csvCell(row.expression)]
            lines.append(cells.joined(separator: ","))
        }
        return "\u{FEFF}" + lines.joined(separator: "\r\n") + "\r\n"
    }

    private static func csvCell(_ s: String) -> String { ClipListingExport.csvCell(s) }

    /// プロジェクトから行を作った結果(書けなかったボイスの数つき)。
    public struct ProjectRows: Equatable {
        public var rows: [Row]
        public var skipped: Int
    }

    /// プロジェクトのボイスクリップを開始時刻の順に行にする(`VoiceScriptExport` と同じ並び・同じ対象外の数え方)。
    public static func rows(from project: Project) -> ProjectRows {
        let voices = project.allClips.enumerated().filter { $0.element.type == .voice }
            .sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }
        var rows: [Row] = []
        var skipped = 0
        for (_, c) in voices {
            let (tag, bodyRaw) = ExpressionTag.split(c.text ?? "")
            let body = bodyRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty, let who = project.characters.first(where: { $0.id == c.charId }), !who.name.isEmpty else {
                skipped += 1
                continue
            }
            let row: Row
            if let sub = c.subtitleText, sub.isEmpty {
                // 字幕なしはそのまま(セリフ = 読み上げ文、字幕 = 明示的に空)
                row = Row(characterName: who.name, dialogue: body, subtitle: "", expression: tag ?? "")
            } else if let sub = c.subtitleText, sub != body {
                // 字幕文が別にある = 元の表記が字幕側にある形(読み辞書で読みだけ変えたクリップ等)。
                // セリフ欄に元の表記、読み欄に読み上げ文を置くと、読み込みで同じクリップに戻る
                row = Row(characterName: who.name, dialogue: sub, reading: body, expression: tag ?? "")
            } else {
                row = Row(characterName: who.name, dialogue: body, expression: tag ?? "")
            }
            rows.append(row)
        }
        return ProjectRows(rows: rows, skipped: skipped)
    }

    /// プロジェクトの台本 CSV 書き出しの結果。
    public struct ExportResult: Equatable {
        public var text: String
        public var lineCount: Int
        public var skipped: Int
    }

    /// プロジェクトのボイスクリップを台本 CSV にする。
    public static func csv(from project: Project) -> ExportResult {
        let r = rows(from: project)
        return ExportResult(text: csv(from: r.rows), lineCount: r.rows.count, skipped: r.skipped)
    }
}
