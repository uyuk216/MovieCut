import XCTest
@testable import MovieCutCore

/// 選択クリップの「再生ヘッドに揃える」「つなげて並べる」の純粋ロジック。
final class TimelineAlignmentTests: XCTestCase {
    private func clip(_ id: String, start: Double, duration: Double) -> Clip {
        var c = Clip()
        c.id = id
        c.start = start
        c.duration = duration
        return c
    }

    private func project(_ layers: [(name: String, locked: Bool, clips: [Clip])]) -> Project {
        var p = Project.new()
        p.tracks = layers.map { l in
            var t = Track(name: l.name)
            t.locked = l.locked ? true : nil
            t.clips = l.clips
            return t
        }
        return p
    }

    private func starts(_ p: Project) -> [String: Double] {
        Dictionary(uniqueKeysWithValues: p.allClips.map { ($0.id, $0.start) })
    }

    // MARK: 再生ヘッドに揃える

    func testAlignMovesEarliestToPlayheadAndKeepsOffsets() throws {
        let p = project([("A", false, [clip("a", start: 2, duration: 1)]), ("B", false, [clip("b", start: 5, duration: 1)])])
        let r = try XCTUnwrap(TimelineAlignment.alignToPlayhead(in: p, clipIds: ["a", "b"], playhead: 10))
        let s = starts(r)
        XCTAssertEqual(s["a"] ?? -1, 10, accuracy: 1e-9, "一番手前が再生ヘッドに来る")
        XCTAssertEqual(s["b"] ?? -1, 13, accuracy: 1e-9, "残りは同じ量だけずれる(相対位置は保つ)")
        XCTAssertEqual(r.tracks.map { $0.clips.map(\.id) }, p.tracks.map { $0.clips.map(\.id) }, "レイヤーは変えない")
    }

    func testAlignSameStartIsNoChange() {
        let p = project([("A", false, [clip("a", start: 4, duration: 1)])])
        XCTAssertNil(TimelineAlignment.alignToPlayhead(in: p, clipIds: ["a"], playhead: 4), "変わらないなら nil(履歴に載せない)")
    }

    func testAlignSkipsLockedLayers() throws {
        let p = project([("A", true, [clip("locked", start: 1, duration: 1)]), ("B", false, [clip("free", start: 3, duration: 1)])])
        let r = try XCTUnwrap(TimelineAlignment.alignToPlayhead(in: p, clipIds: ["locked", "free"], playhead: 0))
        XCTAssertEqual(starts(r)["locked"], 1, "ロックされたレイヤーのクリップは動かさない")
        XCTAssertEqual(starts(r)["free"], 0)
    }

    func testAlignWithNothingEditableIsNil() {
        let p = project([("A", true, [clip("locked", start: 1, duration: 1)])])
        XCTAssertNil(TimelineAlignment.alignToPlayhead(in: p, clipIds: ["locked"], playhead: 5))
        XCTAssertNil(TimelineAlignment.alignToPlayhead(in: p, clipIds: ["missing"], playhead: 5))
    }

    // MARK: つなげて並べる

    func testConcatenateButtsClipsInStartOrderFromEarliest() throws {
        // 2 つのレイヤーに散らばった 3 つを、開始順に隙間なく並べる
        let p = project([
            ("A", false, [clip("x", start: 7, duration: 2), clip("y", start: 1, duration: 3)]),
            ("B", false, [clip("z", start: 4, duration: 1.5)]),
        ])
        let r = try XCTUnwrap(TimelineAlignment.concatenate(in: p, clipIds: ["x", "y", "z"]))
        let s = starts(r)
        XCTAssertEqual(s["y"] ?? -1, 1, accuracy: 1e-9, "一番手前(1 秒)から始まる")
        XCTAssertEqual(s["z"] ?? -1, 4, accuracy: 1e-9, "y の終わり(4 秒)に続く")
        XCTAssertEqual(s["x"] ?? -1, 5.5, accuracy: 1e-9, "z の終わり(5.5 秒)に続く")
        XCTAssertEqual(r.tracks[0].clips.map(\.id), ["x", "y"], "レイヤーの中の順と所属は変えない")
        XCTAssertEqual(r.tracks[1].clips.map(\.id), ["z"])
    }

    func testConcatenateNeedsAtLeastTwoEditableClips() {
        let p = project([("A", false, [clip("only", start: 3, duration: 1)]), ("L", true, [clip("locked", start: 0, duration: 1)])])
        XCTAssertNil(TimelineAlignment.concatenate(in: p, clipIds: ["only"]), "1 つだけなら並べるものがない")
        XCTAssertNil(TimelineAlignment.concatenate(in: p, clipIds: ["only", "locked"]), "ロックを除くと 1 つになる")
    }

    func testConcatenateAlreadyButtedIsNoChange() {
        let p = project([("A", false, [clip("a", start: 0, duration: 2), clip("b", start: 2, duration: 1)])])
        XCTAssertNil(TimelineAlignment.concatenate(in: p, clipIds: ["a", "b"]))
    }
}
