import Foundation

/// タイムラインの範囲選択(時間の範囲 + 対象レイヤー)。ルーラーの ⌥ ドラッグで作る、編集操作のための選択。
///
/// 書き出し範囲(プロジェクトの `rangeIn` / `rangeOut`、ファイルに保存される)とは別のもので、こちらは保存しない
/// (アプリの表示状態として持つ)。範囲に対する破壊的な操作は、既存の `ClipEditing.deleteRange` に
/// 対象レイヤーを渡して行う(削除の実装は 1 つだけにし、二重管理しない)。
public struct RangeSelection: Equatable, Sendable {
    /// 開始・終了(秒)。`start < end`。
    public var start: Double
    public var end: Double
    /// 対象レイヤーの番号。nil は全レイヤー。
    public var trackIndices: Set<Int>?

    public init(start: Double, end: Double, trackIndices: Set<Int>? = nil) {
        self.start = start
        self.end = end
        self.trackIndices = trackIndices
    }

    public var duration: Double { end - start }

    /// ドラッグの 2 点(始点・現在点。どちら向きでもよい)とプロジェクトの終わりから作る。
    /// [0, endTime] に収め、長さが `ExportRange.minLength` 未満(≒クリック)なら nil。
    public static func make(from a: Double, to b: Double, endTime: Double, trackIndices: Set<Int>? = nil) -> RangeSelection? {
        guard endTime > 0, a.isFinite, b.isFinite else { return nil }
        let lo = min(max(0, min(a, b)), endTime)
        let hi = min(max(0, max(a, b)), endTime)
        guard hi - lo >= ExportRange.minLength else { return nil }
        return RangeSelection(start: lo, end: hi, trackIndices: trackIndices)
    }

    /// そのレイヤーが対象か(nil = 全レイヤー対象)。
    public func includesTrack(_ index: Int) -> Bool { trackIndices?.contains(index) ?? true }

    /// レイヤー構成が変わったときに、消えたレイヤーを対象から落とす(対象が空になったら nil を返す)。
    public func pruned(trackCount: Int) -> RangeSelection? {
        guard let s = trackIndices else { return self }
        let kept = s.filter { $0 >= 0 && $0 < trackCount }
        if kept.isEmpty { return nil }
        return RangeSelection(start: start, end: end, trackIndices: kept)
    }
}

/// 範囲選択に対する読み取り系の操作(純粋な計算。選択は `TimelineSelection` の仕組みにそのまま渡す)。
public enum RangeSelectionEditing {
    /// 範囲に(少しでも)かかるクリップの id(開始の早い順)。対象レイヤーだけを見る。
    /// 判定は範囲削除の「触れる」と同じ(端が接するだけのクリップは含めない)。
    public static func clipIds(in project: Project, selection: RangeSelection) -> [String] {
        let eps = ClipEditing.timeEpsilon
        var hit = Set<String>()
        for (ti, tr) in project.tracks.enumerated() where selection.includesTrack(ti) {
            for c in tr.clips where c.start < selection.end - eps && c.start + c.duration > selection.start + eps {
                hit.insert(c.id)
            }
        }
        return ClipEditing.clipsByStart(project).map(\.id).filter { hit.contains($0) }
    }

    /// 範囲内のクリップを選んだ選択(主は開始の一番早いもの)。範囲にクリップが無ければ空。
    public static func clipSelection(in project: Project, selection: RangeSelection) -> ClipSelection {
        let ids = clipIds(in: project, selection: selection)
        guard let first = ids.first else { return .empty }
        return ClipSelection(ids: Set(ids), primary: first)
    }
}
