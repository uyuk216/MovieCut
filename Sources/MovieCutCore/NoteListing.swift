import Foundation

/// 注記(クリップのメモ)の一覧。並びは使用クリップ一覧と同じ(開始時刻順、同じ時刻はレイヤーの並び順)。書き出しには入らない作業用のメモ。
public enum NoteListing {
    public struct Entry: Equatable, Identifiable {
        public var clipId: String
        public var trackName: String
        public var start: Double
        public var note: String
        public var id: String { clipId }
    }

    /// 注記のあるクリップだけを、開始時刻順に並べる。
    public static func entries(in p: Project) -> [Entry] {
        let notes = Dictionary(p.allClips.compactMap { c in c.note.map { (c.id, $0) } }, uniquingKeysWith: { a, _ in a })
        return TimelineQuery.clipListing(in: p).compactMap { e in
            guard let n = notes[e.clipId] else { return nil }
            return Entry(clipId: e.clipId, trackName: e.trackName, start: e.start, note: n)
        }
    }

    /// テキスト(1 件 1 行: 「0.000 秒 [レイヤー] 注記」)。
    public static func text(_ entries: [Entry]) -> String {
        entries.map { "\(String(format: "%.3f", $0.start)) 秒 [\($0.trackName)] \($0.note.replacingOccurrences(of: "\n", with: " "))" }
            .joined(separator: "\n") + (entries.isEmpty ? "" : "\n")
    }

    /// CSV(見出し行つき・先頭は UTF-8 の BOM・引用符は RFC 4180 どおり)。
    public static func csv(_ entries: [Entry]) -> String {
        let rows = [["レイヤー", "開始(秒)", "注記"]] + entries.map { [$0.trackName, String(format: "%.3f", $0.start), $0.note] }
        return "\u{FEFF}" + rows.map { row in row.map(ClipListingExport.csvCell).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }
}
