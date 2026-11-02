import Foundation

extension TimelineQuery.ListEntry: Identifiable {
    public var id: String { clipId }
}

/// 使用クリップ一覧(`TimelineQuery.clipListing`)を TSV・CSV の文字列にする(画面に依存しない)。
/// 列: レイヤー・名前・開始(秒)・長さ(秒)・素材パス。時刻は小数 3 桁で、小数点は「.」固定。
public enum ClipListingExport {
    public static let header = ["レイヤー", "名前", "開始(秒)", "長さ(秒)", "素材パス"]

    /// 1 行ぶんの値(書き出し形式に関係なく同じ並び)。
    public static func cells(_ e: TimelineQuery.ListEntry) -> [String] {
        [e.trackName, e.label, seconds(e.start), seconds(e.duration), e.source ?? ""]
    }

    /// タブ区切り(見出し行つき)。セルの中のタブ・改行は空白にする(列がずれないように)。
    public static func tsv(_ entries: [TimelineQuery.ListEntry]) -> String {
        ([header] + entries.map(cells)).map { row in row.map(tsvCell).joined(separator: "\t") }.joined(separator: "\n") + "\n"
    }

    /// CSV(RFC 4180 の引用符つき・見出し行つき・先頭に UTF-8 の BOM。表計算ソフトで日本語が崩れないように)。
    public static func csv(_ entries: [TimelineQuery.ListEntry]) -> String {
        "\u{FEFF}" + ([header] + entries.map(cells)).map { row in row.map(csvCell).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    static func seconds(_ v: Double) -> String { String(format: "%.3f", v) }

    static func tsvCell(_ s: String) -> String {
        s.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    }

    public static func csvCell(_ s: String) -> String {
        guard s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
