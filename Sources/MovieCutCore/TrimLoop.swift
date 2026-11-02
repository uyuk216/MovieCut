import Foundation

/// トリム点・選択クリップの反復再生で使う範囲の計算(純粋な計算。ループの動き自体は `ExportRangeLoop` を使う)。
public enum TrimLoop {
    /// 反復再生の半幅(秒)の選択肢。
    public static let halfWidthChoices: [Double] = [0.5, 1, 2]
    public static let defaultHalfWidth = 1.0

    /// 選択肢以外(壊れた保存値など)は既定に直す。
    public static func normalizedHalfWidth(_ v: Double) -> Double {
        halfWidthChoices.contains(v) ? v : defaultHalfWidth
    }

    /// 反復する範囲。`clipRange` があればそのクリップの範囲(プロジェクトの内側に切り詰める)。
    /// なければ `playhead ± halfWidth`。端にかかるときは、幅(2 × halfWidth)を保つよう反対側へずらす
    /// (プロジェクトが幅より短ければ全体)。空のプロジェクト・長さの無い範囲は nil。
    public static func loopRange(playhead: Double, halfWidth: Double, duration: Double, clipRange: ExportRange?) -> ExportRange? {
        guard duration.isFinite, duration > ExportRange.minLength else { return nil }
        if let c = clipRange {
            let s = max(0, c.start), e = min(duration, c.end)
            guard s.isFinite, e.isFinite, e - s >= ExportRange.minLength else { return nil }
            return ExportRange(start: s, end: e)
        }
        guard playhead.isFinite else { return nil }
        let h = halfWidth.isFinite && halfWidth > 0 ? halfWidth : defaultHalfWidth
        let width = min(2 * h, duration)
        var s = playhead - h
        s = min(max(0, s), duration - width)
        return ExportRange(start: s, end: s + width)
    }
}
