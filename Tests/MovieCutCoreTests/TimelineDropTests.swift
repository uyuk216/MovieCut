import XCTest
@testable import MovieCutCore

/// 素材のドロップ先(時刻の吸着・行のレイヤー・置けないときのレイヤー)の純粋ロジック。
final class TimelineDropTests: XCTestCase {
    private func clip(_ id: String, start: Double, duration: Double) -> Clip {
        var c = Clip()
        c.id = id
        c.start = start
        c.duration = duration
        return c
    }

    private func project(_ layers: [(name: String, clips: [Clip])]) -> Project {
        var p = Project.new()
        p.tracks = layers.map { l in
            var t = Track(name: l.name)
            t.clips = l.clips
            return t
        }
        return p
    }

    private func place(_ dropTime: Double, dur: Double = 2, row: Int? = 0, p: Project, playhead: Double = 99, pps: Double = 100, snap: Bool = true) -> TimelineDrop.Placement {
        TimelineDrop.placement(dropTime: dropTime, duration: dur, rowIndex: row, project: p, playhead: playhead, pps: pps, snapEnabled: snap)
    }

    // MARK: 時刻の吸着

    func testDropSnapsStartToPlayhead() {
        let p = project([("A", [])])
        // 8pt 以内(pps 100 なら 0.08 秒)の再生ヘッドへ吸着
        XCTAssertEqual(place(5.05, p: p, playhead: 5).start, 5, accuracy: 1e-9)
        XCTAssertEqual(place(5.2, p: p, playhead: 5).start, 5.2, accuracy: 1e-9, "遠ければ吸着しない")
    }

    func testDropSnapsStartToClipEdge() {
        let p = project([("A", [clip("x", start: 10, duration: 3)])])
        XCTAssertEqual(place(13.04, p: p).start, 13, accuracy: 1e-9, "他のクリップの終わりへ")
        XCTAssertEqual(place(9.95, p: p).start, 10, accuracy: 1e-9, "他のクリップの頭へ")
    }

    func testDropSnapsEndWhenStartDoesNotSnap() {
        // 頭は何にも当たらないが、終わり(4 + 2 = 6)がクリップの頭 6 に当たる → 頭を 4 にずらす
        let p = project([("A", [clip("x", start: 6, duration: 1)])])
        XCTAssertEqual(place(4, dur: 2, p: p).start, 4, accuracy: 1e-9, "頭も終わりも当たらなければ、そのまま")
        XCTAssertEqual(place(3.97, dur: 2, p: p).start, 4, accuracy: 1e-9, "終わりが 6 に当たれば頭を 4 へ")
    }

    func testDropSnapsToMarkerAndRangeIn() {
        var p = project([("A", [])])
        var m = Marker()
        m.time = 7
        p.markers = [m]
        p.rangeIn = 2
        XCTAssertEqual(place(6.95, p: p).start, 7, accuracy: 1e-9)
        XCTAssertEqual(place(2.03, p: p).start, 2, accuracy: 1e-9, "範囲の印の in にも当たる")
    }

    func testSnapOffMeansExactTime() {
        let p = project([("A", [])])
        XCTAssertEqual(place(5.05, p: p, playhead: 5, snap: false).start, 5.05, accuracy: 1e-9)
    }

    func testNegativeOrNonFiniteDropIsClampedToZero() {
        let p = project([("A", [])])
        XCTAssertEqual(place(-3, p: p, playhead: 50).start, 0, "負の時刻は 0")
        XCTAssertEqual(place(.nan, p: p, playhead: 50).start, 0)
    }

    // MARK: 行(レイヤー)

    func testRowInsideTracksIsTheTargetLayer() {
        let p = project([("A", []), ("B", [])])
        XCTAssertEqual(place(1, row: 1, p: p).track, 1)
        XCTAssertNil(place(1, row: 5, p: p).track, "範囲外の行は空いているレイヤーへ任せる")
        XCTAssertNil(place(1, row: nil, p: p).track, "行の外(ヘッダー・ルーラー)")
    }

    // MARK: 置き先のレイヤー(ClipEditing.place)

    func testPlaceUsesPreferredLayerWhenFree() {
        var p = project([("A", [clip("x", start: 0, duration: 1)]), ("B", [])])
        let ids = ClipEditing.place(media: [("/m/a.mp4", .video, 2)], at: 5, preferredTrack: 1, in: &p)
        XCTAssertEqual(ids.count, 1)
        XCTAssertEqual(p.tracks[1].clips.map(\.id), ids, "落とした行(B)に入る")
        assertNoLayerOverlaps(p)
    }

    func testPlaceFallsBackWhenPreferredLayerIsOccupied() {
        var p = project([("A", [clip("x", start: 4, duration: 4)]), ("B", [])])
        let ids = ClipEditing.place(media: [("/m/a.mp4", .video, 2)], at: 5, preferredTrack: 0, in: &p)
        XCTAssertEqual(p.tracks[0].clips.map(\.id), ["x"], "重なるレイヤーには置かない")
        XCTAssertEqual(p.tracks[1].clips.map(\.id), ids, "空いている最初のレイヤーへ")
        assertNoLayerOverlaps(p)
    }

    func testPlaceFallsBackWhenPreferredLayerIsLockedOrMissing() {
        var locked = project([("A", []), ("B", [])])
        locked.tracks[0].locked = true
        let a = ClipEditing.place(media: [("/m/a.mp4", .video, 2)], at: 0, preferredTrack: 0, in: &locked)
        XCTAssertEqual(locked.tracks[1].clips.map(\.id), a, "ロックのレイヤーは使わない")

        var p = project([("A", [])])
        let b = ClipEditing.place(media: [("/m/b.mp4", .video, 2)], at: 0, preferredTrack: 9, in: &p)
        XCTAssertEqual(p.tracks[0].clips.map(\.id), b, "存在しない番号は無視")
    }

    func testPlaceManyKeepsSameLayerNonOverlapping() {
        var p = project([("A", []), ("B", [])])
        let media: [(path: String, kind: ClipType, duration: Double)] = [("/m/1.mp4", .video, 2), ("/m/2.mp4", .video, 3)]
        _ = ClipEditing.place(media: media, at: 1, preferredTrack: 1, in: &p)
        XCTAssertEqual(p.tracks[1].clips.map(\.start), [1, 3], "同じレイヤーに続けて並ぶ")
        assertNoLayerOverlaps(p)
    }
}
