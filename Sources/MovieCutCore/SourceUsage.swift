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
