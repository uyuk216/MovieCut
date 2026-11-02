import Foundation

/// クリップが元の素材のどの区間を使っているか(秒)。元素材の上にサブクリップの範囲を示すのに使う(純粋な計算)。
public enum SourceUsage {
    /// 素材の時刻の区間。素材の動画・音声のクリップだけ。フリーズ・空・長さの無い区間は nil。
    /// 逆再生でも、使う区間は同じ(頭 = offset、終わり = offset + 使う長さ)。素材の長さ(srcDuration)があれば越えない。
    public static func range(of c: Clip) -> TimelineQuery.TimeSpan? {
        guard ClipEditing.hasSourceTimeline(c.type), !c.isFreeze else { return nil }
        let s = max(0, c.offset)
        var e = s + ClipTiming.sourceSpan(c)
        if let d = c.srcDuration, d.isFinite, d > 0 { e = min(e, d) }
        guard s.isFinite, e.isFinite, e - s > 1e-6 else { return nil }
        return TimelineQuery.TimeSpan(start: s, end: e)
    }
}

extension SourceUsage {
    /// 表示用の文: 「ソースの使用範囲 00:00–00:00」(1 時間以上は 0:00:00)。範囲が無ければ nil。
    public static func label(of c: Clip) -> String? {
        guard let r = range(of: c) else { return nil }
        return "ソースの使用範囲 \(clock(r.start))–\(clock(r.end))"
    }

    /// 秒を「mm:ss」(切り捨て)。1 時間以上は「h:mm:ss」。
    public static func clock(_ t: Double) -> String {
        let s = max(0, Int(t.rounded(.down)))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
    }
}
