import Foundation

// MARK: - 素材のドロップ先(時刻・レイヤー・吸着)

/// タイムラインへ素材を落としたときの置き場所を決める純粋関数。
/// 時刻は吸着(0・再生ヘッド・他のクリップの頭と終わり・マーカー・範囲の印)に `ClipEditing.snapPoint` を使う。
/// 頭を吸着しなければ、終わりを吸着する(本体のドラッグと同じ順)。
public enum TimelineDrop {
    public struct Placement: Equatable {
        /// 置く時刻(秒。0 以上)。
        public var start: Double
        /// 落とした行のレイヤー番号。行の外(ヘッダー・ルーラーの上など)なら nil(空いている最初のレイヤーへ)。
        public var track: Int?
    }

    /// `dropTime`: 落とした位置の時刻(吸着前)。`duration`: 先頭の素材の長さ。`rowIndex`: 落とした行(レイヤー番号)。
    public static func placement(dropTime: Double, duration: Double, rowIndex: Int?, project: Project,
                                 playhead: Double, pps: Double, snapEnabled: Bool) -> Placement {
        let t = max(0, dropTime.isFinite ? dropTime : 0)
        let dur = max(0, duration.isFinite ? duration : 0)
        var start = t
        if let sp = ClipEditing.snapPoint(t, excluding: nil, project: project, playhead: playhead, pps: pps, enabled: snapEnabled) {
            start = sp
        } else if let ep = ClipEditing.snapPoint(t + dur, excluding: nil, project: project, playhead: playhead, pps: pps, enabled: snapEnabled) {
            start = max(0, ep - dur)
        }
        let track = rowIndex.flatMap { project.tracks.indices.contains($0) ? $0 : nil }
        return Placement(start: start, track: track)
    }
}
