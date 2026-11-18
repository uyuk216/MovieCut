import XCTest
@testable import MovieCutCore

/// 範囲選択(#23): 時間の範囲 + 対象レイヤーのモデル、範囲内のクリップの取得、
/// 範囲の削除のレイヤー限定版(実装は既存の `ClipEditing.deleteRange` の 1 つだけ)。
final class RangeSelectionTests: XCTestCase {
    // MARK: 道具

    private func clip(_ id: String, _ start: Double, _ dur: Double) -> Clip {
        var c = Clip(); c.id = id; c.type = .text; c.start = start; c.duration = dur; return c
    }

    private func project(_ tracks: [[Clip]]) -> Project {
        var p = Project()
        p.tracks = tracks.map { var t = Track(name: "t"); t.clips = $0; return t }
        return p
    }

    // MARK: 作る

    func testMakeNormalizesAndClamps() {
        XCTAssertEqual(RangeSelection.make(from: 5, to: 2, endTime: 10), RangeSelection(start: 2, end: 5))
        XCTAssertEqual(RangeSelection.make(from: -3, to: 99, endTime: 10), RangeSelection(start: 0, end: 10))
        XCTAssertNil(RangeSelection.make(from: 2, to: 2.0005, endTime: 10))       // 短すぎる = クリック
        XCTAssertNil(RangeSelection.make(from: 1, to: 2, endTime: 0))
        XCTAssertEqual(RangeSelection.make(from: 1, to: 3, endTime: 10, trackIndices: [1])?.trackIndices, [1])
    }

    func testPruned() {
        XCTAssertEqual(RangeSelection(start: 0, end: 5, trackIndices: [0, 3, 9]).pruned(trackCount: 2)?.trackIndices, [0])
        XCTAssertNil(RangeSelection(start: 0, end: 5, trackIndices: [5]).pruned(trackCount: 2))
        XCTAssertEqual(RangeSelection(start: 0, end: 5).pruned(trackCount: 2), RangeSelection(start: 0, end: 5))
    }

    // MARK: 範囲内のクリップ

    func testClipIdsIntersectingInStartOrder() {
        let p = project([[clip("A", 0, 2), clip("B", 2, 2)], [clip("C", 1, 4), clip("D", 6, 1)]])
        let sel = RangeSelection(start: 1.5, end: 3)
        XCTAssertEqual(RangeSelectionEditing.clipIds(in: p, selection: sel), ["A", "C", "B"])
        // 端が接するだけのクリップは含めない(A は 2 で終わる)
        XCTAssertEqual(RangeSelectionEditing.clipIds(in: p, selection: RangeSelection(start: 2, end: 3)), ["C", "B"])
        // 対象レイヤーを限る
        XCTAssertEqual(RangeSelectionEditing.clipIds(in: p, selection: RangeSelection(start: 1.5, end: 3, trackIndices: [1])), ["C"])
        // 選択への変換(主は開始の一番早いもの)
        let cs = RangeSelectionEditing.clipSelection(in: p, selection: sel)
        XCTAssertEqual(cs.ids, ["A", "B", "C"])
        XCTAssertEqual(cs.primary, "A")
        XCTAssertEqual(RangeSelectionEditing.clipSelection(in: p, selection: RangeSelection(start: 10, end: 12)), .empty)
    }

    // MARK: レイヤー限定の範囲削除

    func testScopedDeleteOnlyTouchesScopedTracks() throws {
        let p = project([[clip("A", 0, 6)], [clip("B", 0, 6)]])
        let r = try XCTUnwrap(ClipEditing.deleteRange(in: p, from: 2, to: 4, ripple: false, trackIndices: [0]))
        XCTAssertEqual(r.tracks[0].clips.map { [$0.start, $0.duration] }, [[0, 2], [4, 2]])   // 分割して中を削除
        XCTAssertEqual(r.tracks[1].clips.map { [$0.start, $0.duration] }, [[0, 6]])          // 対象外は割もしない
    }

    func testScopedRippleOnlyShiftsScopedTracks() throws {
        let p = project([[clip("A", 0, 2), clip("C", 4, 2)], [clip("B", 0, 2), clip("D", 4, 2)]])
        let r = try XCTUnwrap(ClipEditing.deleteRange(in: p, from: 1, to: 3, ripple: true, trackIndices: [1]))
        XCTAssertEqual(r.tracks[0].clips.map { [$0.start, $0.duration] }, [[0, 2], [4, 2]])   // 対象外はそのまま
        XCTAssertEqual(r.tracks[1].clips.map { [$0.start, $0.duration] }, [[0, 1], [2, 2]])   // B は 1 秒に、D は 2 秒前へ
    }

    func testScopedDeleteIgnoresLockOutsideScope() throws {
        var locked = clip("B", 0, 6); locked.locked = true
        let p = project([[clip("A", 0, 6)], [locked]])
        XCTAssertNotNil(ClipEditing.deleteRange(in: p, from: 2, to: 4, ripple: false, trackIndices: [0]))
        XCTAssertNil(ClipEditing.deleteRange(in: p, from: 2, to: 4, ripple: false))          // 全レイヤーならロックで中止
        XCTAssertNil(ClipEditing.deleteRange(in: p, from: 2, to: 4, ripple: false, trackIndices: [1]))
    }

    func testUnscopedMatchesLegacyEntryPoint() {
        // 分割で生まれる断片の id は毎回新しいので、配置(開始・長さ)で比べる
        func layout(_ p: Project?) -> [[[Double]]] { (p?.tracks ?? []).map { $0.clips.map { [$0.start, $0.duration] } } }
        let p = project([[clip("A", 0, 6), clip("C", 8, 2)], [clip("B", 1, 3)]])
        XCTAssertEqual(layout(ClipEditing.deleteRange(in: p, from: 2, to: 5, ripple: true)),
                       layout(ClipEditing.deleteRange(in: p, from: 2, to: 5, ripple: true, trackIndices: nil)))
        XCTAssertEqual(layout(ClipEditing.deleteRange(in: p, from: 2, to: 5, ripple: false)),
                       layout(ClipEditing.deleteRange(in: p, from: 2, to: 5, ripple: false, trackIndices: nil)))
    }
}
