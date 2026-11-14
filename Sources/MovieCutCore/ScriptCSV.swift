import Foundation

// MARK: - 台本 CSV の読み込み
//
// スプレッドシートで作った台本(CSV)を、台本テキストの行(「名前: 読み上げ文 | 字幕文」)に直す。
// あとは通常の台本と同じ経路(`ScriptTimeline.add`)で声になる。計算は純粋(ファイル読み込みは呼び出し側)。
//
// 列の並び:
// - 見出し行があれば列名で対応づける(名前/キャラ/話者、セリフ/読み上げ/読み/発音、字幕)。
// - 見出しが無ければ「名前,読み上げ文,字幕文」の順。列が 1 つだけなら読み上げ文だけの台本として読む。
// - 字幕のセルが空なら字幕の指定なし(読み上げ文と同じ)。※ で始まる行はメモ行としてそのまま通す。

public enum ScriptCSV {
    /// CSV のテキストを行列に分解する(引用符・中のカンマと改行・"" のエスケープ・CRLF に対応)。
    public static func rows(fromCSV text: String) -> [[String]] {
        // unicodeScalars で見る(CRLF が Character では 1 つの書記素クラスタになり、改行として判定できないため)
        var rows: [[String]] = []
        var row: [String] = []
        var cell = ""
        var inQuotes = false
        let scalars = Array(text.unicodeScalars)
        var i = 0
        func endCell() { row.append(cell); cell = "" }
        func endRow() { endCell(); rows.append(row); row = [] }
        while i < scalars.count {
            let ch = scalars[i]
            if inQuotes {
                if ch == "\"" {
                    if i + 1 < scalars.count, scalars[i + 1] == "\"" { cell.unicodeScalars.append("\""); i += 2 } else { inQuotes = false; i += 1 }
                } else { cell.unicodeScalars.append(ch); i += 1 }
                continue
            }
            switch ch {
            case "\"" where cell.isEmpty: inQuotes = true; i += 1
            case ",": endCell(); i += 1
            case "\r": endRow(); i += (i + 1 < scalars.count && scalars[i + 1] == "\n") ? 2 : 1
            case "\n": endRow(); i += 1
            default: cell.unicodeScalars.append(ch); i += 1
            }
        }
        if !cell.isEmpty || !row.isEmpty { endRow() }
        return rows
    }

    static let nameHeaders: Set<String> = ["名前", "キャラ", "キャラクター", "キャラクター名", "話者"]
    static let spokenHeaders: Set<String> = ["セリフ", "台詞", "読み上げ", "読み上げ文", "読み", "発音", "本文"]
    static let subtitleHeaders: Set<String> = ["字幕", "字幕文", "表示"]

    /// CSV のテキストを台本の行に直す。
    public static func lines(fromCSV text: String) -> [String] {
        let text = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        var rows = rows(fromCSV: text)
        guard !rows.isEmpty else { return [] }

        var nameIdx: Int? = 0, spokenIdx = 1, subtitleIdx: Int? = 2
        // 見出し行(列名のどれかを含む行)があれば対応づけ直す
        if let h = rows.first?.map({ $0.trimmingCharacters(in: .whitespaces) }),
           h.contains(where: { spokenHeaders.contains($0) || subtitleHeaders.contains($0) }) {
            nameIdx = h.firstIndex(where: { nameHeaders.contains($0) })
            spokenIdx = h.firstIndex(where: { spokenHeaders.contains($0) }) ?? 1
            subtitleIdx = h.firstIndex(where: { subtitleHeaders.contains($0) })
            rows.removeFirst()
        } else if rows.allSatisfy({ $0.count <= 1 }) {
            nameIdx = nil; spokenIdx = 0; subtitleIdx = nil   // 1 列だけ = セリフだけ
        }

        var out: [String] = []
        for row in rows {
            let cells = row.map { $0.trimmingCharacters(in: .whitespaces) }
            if cells.allSatisfy({ $0.isEmpty }) { continue }
            if let note = cells.first(where: { !$0.isEmpty }), note.hasPrefix("※") { out.append(note); continue }
            func cell(_ idx: Int?) -> String { guard let idx, idx < cells.count else { return "" }; return cells[idx] }
            let spoken = cell(spokenIdx)
            guard !spoken.isEmpty else { continue }
            let name = cell(nameIdx), sub = cell(subtitleIdx)
            var line = name.isEmpty ? spoken : "\(name): \(spoken)"
            if !sub.isEmpty { line += " | \(sub)" }
            out.append(line)
        }
        return out
    }
}
