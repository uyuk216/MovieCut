import Foundation

/// YouTube のチャプター(説明欄に貼る `0:00 題名` の行)を、タイムラインのマーカーから作る(B3。純粋な整形)。
public enum Chapters {
    /// YouTube の条件: 3 つ以上、最初は 0:00、各チャプターは 10 秒以上。
    public static let minCount = 3
    public static let minGap = 10.0
    /// 0:00 のマーカーが無いときに足す先頭の題。
    public static let introTitle = "イントロ"

    public struct Result: Equatable {
        public var text: String
        public var count: Int
        public var warnings: [String]
    }

    /// `m:ss`(1 時間以上は `h:mm:ss`)。秒は切り捨て。
    public static func timecode(_ t: Double) -> String {
        let s = Int((t.isFinite ? max(0, t) : 0).rounded(.down))
        let h = s / 3600, m = s / 60 % 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// 題は 1 行にまとめる(改行は空白に)。空なら「チャプター」。
    static func title(_ name: String) -> String {
        let t = name.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        return t.isEmpty ? "チャプター" : t
    }

    /// マーカーからチャプターを作る。時刻順。最初が 0:00(1 秒未満)でなければ、先頭に「イントロ」を足す(足したことを注意に出す)。
    /// マーカーが無いときは text が空で、注意だけ返す。
    /// `color` を指定すると、その色のマーカーだけを使う(色が未設定・未知の値のマーカーは既定のティール)。
    public static func make(from all: [Marker], color: MarkerColor? = nil) -> Result {
        let markers = color.map { c in all.filter { MarkerColor.resolved($0.color) == c } } ?? all
        if let color, markers.isEmpty {
            return Result(text: "", count: 0, warnings: ["\(color.title)のマーカーがありません"])
        }
        guard !markers.isEmpty else { return Result(text: "", count: 0, warnings: ["マーカーがありません。再生位置にマーカーを追加してください"]) }
        var items = MarkerEditing.sorted(markers).map { (time: $0.time, title: title($0.name)) }
        var warnings: [String] = []
        if Int(items[0].time.rounded(.down)) != 0 {
            items.insert((0, introTitle), at: 0)
            warnings.append("0:00 のマーカーが無いので、先頭に「\(introTitle)」を足しました(YouTube は最初が 0:00 のときだけチャプターにします)")
        }
        if items.count < minCount {
            warnings.append("チャプターが \(items.count) つしかありません(YouTube は 3 つ以上必要です)")
        }
        var close = 0
        for i in 1..<items.count where items[i].time - items[i - 1].time < minGap - 1e-9 { close += 1 }
        if close > 0 { warnings.append("10 秒より近いチャプターが \(close) か所あります(YouTube は各チャプター 10 秒以上必要です)") }
        let text = items.map { "\(timecode($0.time)) \($0.title)" }.joined(separator: "\n")
        return Result(text: text, count: items.count, warnings: warnings)
    }

    /// 色ごとのマーカーの数(未設定・未知の値はティールに数える)。メニューの有効判定に使う。
    public static func colorCounts(_ markers: [Marker]) -> [MarkerColor: Int] {
        var out: [MarkerColor: Int] = [:]
        for m in markers { out[MarkerColor.resolved(m.color), default: 0] += 1 }
        return out
    }
}
