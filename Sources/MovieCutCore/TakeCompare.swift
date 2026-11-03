import Foundation

/// 同じ台詞の別テイクを並べて比較する(候補 35)。
/// 「同じ台詞」= ボイスクリップのセリフ(表情タグ `[笑顔]` を除き、空白・全角半角・大文字小文字・濁点の違いを無視)が同じもの。
/// 2 つ以上あるグループを時刻順に並べ、長さ・音の大きさ・頭と終わりの無音を比べる。選んだ 1 つを残して他を取り除ける。
public enum TakeCompare {
    public struct Take: Equatable, Identifiable {
        public var id: String { clipId }
        public var clipId: String
        public var trackIndex: Int
        public var trackName: String
        public var start: Double
        public var duration: Double
        public var charId: String?
        public var src: String?
    }

    public struct Group: Equatable, Identifiable {
        public var id: String { key }
        /// 比べるときの正規化したセリフ。
        public var key: String
        /// 表示に使うセリフ(最初のテイクの本文)。
        public var text: String
        public var takes: [Take]
    }

    /// セリフの比較用の形。表情タグを除き、空白をすべて除き、全角半角・大文字小文字・濁点の差を無視する。空なら nil。
    public static func key(of text: String?) -> String? {
        guard let raw = text else { return nil }
        let body = ExpressionTag.body(raw)
        let folded = body.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        let s = String(folded.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
        return s.isEmpty ? nil : s
    }

    /// 同じセリフのボイスクリップが 2 つ以上あるグループ(最初のテイクの時刻順)。複合クリップの中は対象にしない。
    public static func groups(in project: Project) -> [Group] {
        var table: [String: Group] = [:]
        for (ti, tr) in project.tracks.enumerated() {
            for c in tr.clips where c.type == .voice {
                guard let k = key(of: c.text) else { continue }
                let take = Take(clipId: c.id, trackIndex: ti, trackName: tr.name, start: c.start, duration: c.duration, charId: c.charId, src: c.src)
                if var g = table[k] { g.takes.append(take); table[k] = g }
                else { table[k] = Group(key: k, text: ExpressionTag.body(c.text ?? ""), takes: [take]) }
            }
        }
        return table.values.filter { $0.takes.count >= 2 }
            .map { g in var x = g; x.takes.sort { ($0.start, $0.trackIndex, $0.clipId) < ($1.start, $1.trackIndex, $1.clipId) }; return x }
            .sorted { ($0.takes[0].start, $0.key) < ($1.takes[0].start, $1.key) }
    }

    /// 比較の数字。
    public struct Metrics: Equatable {
        /// 声の部分の平均の音量(dBFS。無音の窓を除く)。声が無ければ nil。
        public var averageDb: Double?
        /// 一番大きい窓の音量(dBFS)。
        public var peakDb: Double?
        /// 頭の無音(秒)・終わりの無音(秒)。
        public var leadSilence: Double
        public var trailSilence: Double
        /// 声のある長さ = 全体 − 頭 − 終わりの無音。
        public var speechLength: Double
        public init(averageDb: Double?, peakDb: Double?, leadSilence: Double, trailSilence: Double, speechLength: Double) {
            self.averageDb = averageDb; self.peakDb = peakDb; self.leadSilence = leadSilence
            self.trailSilence = trailSilence; self.speechLength = speechLength
        }
    }

    /// 音の大きさの変化から比較の数字を求める。`thresholdDb` より小さい窓を無音とする。
    public static func metrics(of profile: LevelProfile, thresholdDb: Double = -40) -> Metrics {
        let w = LevelProfile.windowSeconds
        let loud = profile.levels.enumerated().filter { Double($0.element) >= thresholdDb }
        guard let first = loud.first, let last = loud.last else {
            return Metrics(averageDb: nil, peakDb: nil, leadSilence: profile.duration, trailSilence: 0, speechLength: 0)
        }
        // 平均はパワー(2 乗)で平均してから dB に戻す
        let power = loud.reduce(0.0) { $0 + pow(10, Double($1.element) / 10) } / Double(loud.count)
        let lead = Double(first.offset) * w
        let endOfSpeech = min(profile.duration, Double(last.offset + 1) * w)
        return Metrics(averageDb: 10 * log10(power), peakDb: loud.map { Double($0.element) }.max(),
                       leadSilence: lead, trailSilence: max(0, profile.duration - endOfSpeech),
                       speechLength: max(0, endOfSpeech - lead))
    }

    /// クリップの音を読んで比較の数字にする(音が読めなければ nil)。
    public static func metrics(of clip: Clip) -> Metrics? {
        SilenceDetector.analyze(clip: clip).map { metrics(of: $0) }
    }

    /// 選んだテイクだけを残し、同じグループの他のテイクを取り除く。ロックされたレイヤー・クリップのテイクは取り除かない。
    /// 取り除くものが無い・選んだクリップがグループに無いときは nil。
    public static func keepOnly(_ clipId: String, in project: Project) -> (project: Project, removed: [String], skippedLocked: Int)? {
        guard let g = groups(in: project).first(where: { $0.takes.contains { $0.clipId == clipId } }) else { return nil }
        var p = project
        var removed: [String] = []
        var skipped = 0
        for t in g.takes where t.clipId != clipId {
            guard let loc = ClipEditing.locate(t.clipId, in: p) else { continue }
            if p.tracks[loc.track].isLocked || p.tracks[loc.track].clips[loc.index].isClipLocked { skipped += 1; continue }
            p.tracks[loc.track].clips.remove(at: loc.index)
            removed.append(t.clipId)
        }
        guard !removed.isEmpty else { return nil }
        return (p, removed, skipped)
    }
}
