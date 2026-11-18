import XCTest
@testable import MovieCutCore

/// 範囲の削除(ClipEditing.deleteRange): 両端を既存の分割で割り、範囲に入る断片を消す。リップルは各レイヤーで後ろを詰める。
final class ClipRangeDeleteTests: XCTestCase {
    private func clip(_ id: String, start: Double, dur: Double, type: ClipType = .video, offset: Double = 0) -> Clip {
        var c = Clip(); c.id = id; c.type = type; c.start = start; c.duration = dur; c.offset = offset
        return c
    }
    private func project(_ t0: [Clip], _ t1: [Clip] = []) -> Project {
        var p = Project.new()
        p.tracks[0].clips = t0
        p.tracks[1].clips = t1
        return p
    }
    private func find(_ id: String, _ p: Project) -> Clip? { p.tracks.flatMap(\.clips).first { $0.id == id } }

    func testClipsFullyInsideAreDeletedOnAllTracks() throws {
        let p = project([clip("a", start: 0, dur: 2), clip("b", start: 3, dur: 1), clip("z", start: 8, dur: 2)],
                        [clip("c", start: 2.5, dur: 1.5)])
        let r = try XCTUnwrap(ClipEditing.deleteRange(in: p, from: 2, to: 5, ripple: false))
        XCTAssertEqual(r.tracks[0].clips.map(\.id), ["a", "z"])
        XCTAssertTrue(r.tracks[1].clips.isEmpty)
        XCTAssertEqual(find("z", r)?.start, 8, "リップルなしは動かさない")
    }

    func testLeftOverlapIsShortenedAndRightOverlapMovesStartAndOffset() throws {
        // 速度 2 倍の右端かかり: 範囲の終わりまで 1 秒切ると素材は 2 秒進む
        var right = clip("r", start: 4, dur: 4, offset: 1); right.speed = 2
        let p = project([clip("l", start: 0, dur: 3, offset: 0.5), right])
        let r = try XCTUnwrap(ClipEditing.deleteRange(in: p, from: 2, to: 5, ripple: false))
        let l = try XCTUnwrap(find("l", r))
        XCTAssertEqual(l.start, 0); XCTAssertEqual(l.duration, 2, accuracy: 1e-9); XCTAssertEqual(l.offset, 0.5)
        let rr = try XCTUnwrap(r.tracks[0].clips.first { $0.start >= 5 - 1e-9 })
        XCTAssertEqual(rr.start, 5, accuracy: 1e-9); XCTAssertEqual(rr.duration, 3, accuracy: 1e-9)
        XCTAssertEqual(rr.offset, 1 + 1 * 2, accuracy: 1e-9)
    }

    func testClipSpanningRangeIsSplitAndMiddleRemoved() throws {
        let p = project([clip("a", start: 0, dur: 10, offset: 0)])
        let r = try XCTUnwrap(ClipEditing.deleteRange(in: p, from: 3, to: 6, ripple: false))
        XCTAssertEqual(r.tracks[0].clips.count, 2)
        let left = r.tracks[0].clips[0], right = r.tracks[0].clips[1]
        XCTAssertEqual(left.id, "a")
        XCTAssertEqual(left.start, 0); XCTAssertEqual(left.duration, 3, accuracy: 1e-9)
        XCTAssertNotEqual(right.id, "a")
        XCTAssertEqual(right.start, 6, accuracy: 1e-9); XCTAssertEqual(right.duration, 4, accuracy: 1e-9)
        XCTAssertEqual(right.offset, 6, accuracy: 1e-9)
    }

    func testRippleClosesGapPerTrackAndNonRippleDoesNot() throws {
        let p = project([clip("a", start: 0, dur: 2), clip("b", start: 5, dur: 1), clip("c", start: 7, dur: 1)],
                        [clip("d", start: 3, dur: 1), clip("e", start: 6, dur: 2)])
        let rip = try XCTUnwrap(ClipEditing.deleteRange(in: p, from: 2, to: 5, ripple: true))
        XCTAssertEqual(find("a", rip)?.start, 0)
        XCTAssertEqual(find("b", rip)?.start, 2)
        XCTAssertEqual(find("c", rip)?.start, 4)
        XCTAssertNil(find("d", rip))
        XCTAssertEqual(find("e", rip)?.start, 3)
        let flat = try XCTUnwrap(ClipEditing.deleteRange(in: p, from: 2, to: 5, ripple: false))
        XCTAssertEqual(find("b", flat)?.start, 5)
        XCTAssertEqual(find("e", flat)?.start, 6)
    }

    func testRippleOfSpanningClipJoinsRightPieceToLeft() throws {
        let p = project([clip("a", start: 0, dur: 10)])
        let r = try XCTUnwrap(ClipEditing.deleteRange(in: p, from: 3, to: 6, ripple: true))
        XCTAssertEqual(r.tracks[0].clips.map(\.start).map { ($0 * 1000).rounded() / 1000 }, [0, 3])
        XCTAssertEqual(r.endTime, 7, accuracy: 1e-9, "リップル削除で endTime が範囲の幅だけ縮む")
    }

    func testLockedClipOrLayerTouchingRangeReturnsNil() {
        var p = project([clip("a", start: 0, dur: 4), clip("b", start: 6, dur: 2)], [clip("c", start: 1, dur: 1)])
        p.tracks[0].clips[0].locked = true
        XCTAssertNil(ClipEditing.deleteRange(in: p, from: 2, to: 3, ripple: false))
        // ロックされていないクリップの分も含め、何も変わらない(純粋関数なので元は不変)
        let copy = p
        _ = ClipEditing.deleteRange(in: p, from: 2, to: 3, ripple: true)
        XCTAssertEqual(p, copy)

        var q = project([clip("a", start: 0, dur: 4)], [clip("c", start: 1, dur: 1)])
        q.tracks[1].locked = true
        XCTAssertNil(ClipEditing.deleteRange(in: q, from: 0.5, to: 3, ripple: false))
        // 範囲に触れないロックは無関係(リップルでなければ通る)
        XCTAssertNotNil(ClipEditing.deleteRange(in: q, from: 0.5, to: 0.9, ripple: false))
    }

    func testRippleRefusesToMoveLockedClipAfterRange() {
        var p = project([clip("a", start: 0, dur: 2)], [clip("c", start: 6, dur: 2)])
        p.tracks[1].locked = true
        XCTAssertNil(ClipEditing.deleteRange(in: p, from: 0, to: 2, ripple: true))
        XCTAssertNotNil(ClipEditing.deleteRange(in: p, from: 0, to: 2, ripple: false))
    }

    func testEmptyOrUntouchedRangeReturnsNil() {
        let p = project([clip("a", start: 0, dur: 2), clip("b", start: 5, dur: 1)])
        XCTAssertNil(ClipEditing.deleteRange(in: p, from: 3, to: 3, ripple: true), "空範囲")
        XCTAssertNil(ClipEditing.deleteRange(in: p, from: 4, to: 3, ripple: true), "逆順")
        XCTAssertNil(ClipEditing.deleteRange(in: p, from: 2.5, to: 4.5, ripple: false), "何にも触れない")
        XCTAssertNil(ClipEditing.deleteRange(in: p, from: 10, to: 20, ripple: false), "終わりより後ろ")
    }

    func testMarkersAreNotChanged() throws {
        var p = project([clip("a", start: 0, dur: 10)])
        p.markers = [Marker(time: 8, name: "m")]
        let r = try XCTUnwrap(ClipEditing.deleteRange(in: p, from: 3, to: 6, ripple: true))
        XCTAssertEqual(r.markers, p.markers)
    }
}
