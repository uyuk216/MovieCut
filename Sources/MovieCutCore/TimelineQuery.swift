import Foundation

/// タイムラインの問い合わせ(画面に依存しない純粋な計算)。Project を読むだけで、書き換えない。
/// 非表示(hidden)のレイヤーは見た目に出ないので、空白・再生位置のクリップの判定から外す。
public enum TimelineQuery {
    /// 比べるときの許容差(秒)。
    static let eps = 0.0005
    /// 「短いクリップ」とみなすコマ数の既定値(これより短いクリップを選ぶ)。
    public static let shortClipFrames = 6

    public struct TimeSpan: Equatable {
        public var start: Double
        public var end: Double
        public init(start: Double, end: Double) { self.start = start; self.end = end }
    }

    /// 区間を重なり・接しているものを結合し、開始時刻の昇順にする。長さ 0 以下は捨てる。
    static func merged(_ spans: [TimeSpan]) -> [TimeSpan] {
        var out: [TimeSpan] = []
        for s in spans.filter({ $0.end > $0.start }).sorted(by: { $0.start < $1.start }) {
            if var last = out.last, s.start <= last.end + eps {
                last.end = max(last.end, s.end)
                out[out.count - 1] = last
            } else {
                out.append(s)
            }
        }
        return out
    }

    // MARK: 空白(黒穴)

    /// 表示中のクリップが覆う区間(結合済み・昇順)。
    public static func coveredSpans(in p: Project) -> [TimeSpan] {
        merged(p.tracks.filter { !$0.isHidden }.flatMap { $0.clips }.map { TimeSpan(start: $0.start, end: $0.start + $0.duration) })
    }

    /// 空白(何も映らない区間)が始まる時刻の一覧(昇順)。0 秒より後から始まるなら先頭の 0 秒も入る。
    /// 最後のクリップの後ろは空白に数えない(そこから先は何も無いので、飛ぶ先がない)。
    public static func gapStarts(in p: Project) -> [Double] {
        let spans = coveredSpans(in: p)
        guard let first = spans.first else { return [] }
        var starts: [Double] = []
        if first.start > eps { starts.append(0) }
        for s in spans.dropLast() { starts.append(s.end) }
        return starts
    }

    /// 再生位置より後で、いちばん近い空白の始まり。無ければ nil。
    public static func nextGapStart(after t: Double, in p: Project) -> Double? {
        gapStarts(in: p).first { $0 > t + eps }
    }

    /// 再生位置より前で、いちばん近い空白の始まり。無ければ nil。
    public static func previousGapStart(before t: Double, in p: Project) -> Double? {
        gapStarts(in: p).last { $0 < t - eps }
    }

    // MARK: 再生位置のクリップ

    /// 再生位置(t 秒)にあるクリップの id(表示中のレイヤーの並び順・レイヤー内は配列の順)。
    /// 描画は配列の後ろほど手前なので、手前のクリップは一番後ろの要素。
    public static func clipIds(at t: Double, in p: Project) -> [String] {
        p.tracks.filter { !$0.isHidden }.flatMap { tr in
            tr.clips.filter { $0.duration > 0 && t >= $0.start - eps && t < $0.start + $0.duration - eps }.map(\.id)
        }
    }

    // MARK: 短いクリップ・欠けた素材

    /// 指定コマ数より短いクリップ(長さ 0 も含む)の id。コマ数は p.fps で秒に直す。
    public static func shortClipIds(in p: Project, minFrames: Int = shortClipFrames) -> [String] {
        guard p.fps > 0 else { return [] }
        let limit = Double(minFrames) / p.fps
        return p.allClips.filter { $0.duration < limit - 1e-9 }.map(\.id)
    }

    /// 素材が見つからないクリップが置かれている区間(表示中のレイヤー・結合済み)。プレビューで目立たせるのに使う。
    public static func missingSpans(in p: Project, exists: (String) -> Bool) -> [TimeSpan] {
        merged(p.tracks.filter { !$0.isHidden }.flatMap { $0.clips }.compactMap { c in
            guard let src = c.src, !src.isEmpty, !exists(src) else { return nil }
            return TimeSpan(start: c.start, end: c.start + c.duration)
        })
    }

    // MARK: 一覧・範囲・発話時間

    public struct ListEntry: Equatable {
        public var clipId: String
        public var trackName: String
        public var type: ClipType
        public var start: Double
        public var duration: Double
        /// 表示用の名前(文字・セリフは本文、素材は file 名、それ以外は種類)。
        public var label: String
        /// 素材のパス(文字・図形など素材の無いクリップは nil)。一覧の書き出しに使う。
        public var source: String?
    }

    /// 全レイヤーのクリップを開始時刻順に並べる(同じ時刻はレイヤーの並び順)。
    public static func clipListing(in p: Project) -> [ListEntry] {
        var rows: [(index: Int, entry: ListEntry)] = []
        var index = 0
        for tr in p.tracks {
            for c in tr.clips {
                rows.append((index, ListEntry(clipId: c.id, trackName: tr.name, type: c.type, start: c.start, duration: c.duration, label: label(of: c), source: c.src)))
                index += 1
            }
        }
        return rows.sorted { ($0.entry.start, $0.index) < ($1.entry.start, $1.index) }.map(\.entry)
    }

    static func label(of c: Clip) -> String {
        if let t = c.text, !t.isEmpty { return t }
        if let s = c.src, !s.isEmpty { return (s as NSString).lastPathComponent }
        return c.type.rawValue
    }

    /// 選んだクリップの頭から終わりまでの範囲(書き出し範囲に使う)。長さが無ければ nil。
    public static func span(ofClipIds ids: Set<String>, in p: Project) -> ExportRange? {
        let picked = p.allClips.filter { ids.contains($0.id) && $0.duration > 0 }
        guard let a = picked.map(\.start).min(), let b = picked.map({ $0.start + $0.duration }).max() else { return nil }
        return ExportRange.resolve(rangeIn: a, rangeOut: b, endTime: b)
    }

    public struct SpeechShare: Equatable {
        public var charId: String
        public var name: String
        public var seconds: Double
        /// 全体に対する割合(0〜1)。
        public var ratio: Double
    }

    /// ボイス(セリフ)クリップの長さを話者ごとに集計する。並びはキャラの登録順。登録のないキャラのセリフは数えない。
    public static func speechShare(in p: Project) -> [SpeechShare] {
        var secs: [String: Double] = [:]
        for c in p.allClips where c.type == .voice {
            if let id = c.charId { secs[id, default: 0] += c.duration }
        }
        // 登録のないキャラの分は合計にも入れない(割合が 1 にならないのを防ぐ)
        let counted = p.characters.compactMap { ch -> (Character, Double)? in
            guard let s = secs[ch.id], s > 0 else { return nil }
            return (ch, s)
        }
        let total = counted.reduce(0) { $0 + $1.1 }
        guard total > 0 else { return [] }
        return counted.map { ch, s in SpeechShare(charId: ch.id, name: ch.name, seconds: s, ratio: s / total) }
    }
}

// MARK: - 注記(クリップのメモ)

extension Clip {
    /// 注記の最大字数。
    public static let noteMaxLength = 200

    /// 注記の整形: 前後の空白を除き、改行は空白に、200 字まで。空なら nil(保存しない)。
    public static func cleanNote(_ raw: String) -> String? {
        let flat = raw.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        guard !flat.isEmpty else { return nil }
        return String(flat.prefix(noteMaxLength))
    }
}
