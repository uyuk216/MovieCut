import XCTest
@testable import MovieCutCore

/// レイヤーの削除(LayerEditing.delete)。
final class LayerDeleteTests: XCTestCase {
    private func clip(_ id: String, start: Double = 0, dur: Double = 1) -> Clip {
        var c = Clip(); c.id = id; c.type = .image; c.start = start; c.duration = dur
        return c
    }

    private func sample() -> Project {
        var p = Project.new()
        p.tracks[0].clips = [clip("a"), clip("b", start: 2)]
        p.tracks[1].clips = [clip("c")]
        p.tracks[2].locked = true
        p.tracks[2].clips = [clip("d")]
        return p
    }

    func testDeleteRemovesLayerAndItsClipsOnly() {
        let p = sample()
        let q = LayerEditing.delete(in: p, index: 0)!
        XCTAssertEqual(q.tracks.count, p.tracks.count - 1)
        XCTAssertEqual(q.tracks.map(\.id), Array(p.tracks.dropFirst()).map(\.id), "残りの順番と id はそのまま")
        XCTAssertEqual(q.allClips.map(\.id).sorted(), ["c", "d"])
        XCTAssertEqual(q.tracks, Array(p.tracks.dropFirst()), "ほかのレイヤーの中身は変わらない")
        assertNoLayerOverlaps(q)
    }

    func testDeleteMiddleAndLast() {
        let p = sample()
        XCTAssertEqual(LayerEditing.delete(in: p, index: 1)!.tracks.map(\.id), [p.tracks[0].id] + p.tracks[2...].map(\.id))
        let last = p.tracks.count - 1
        XCTAssertEqual(LayerEditing.delete(in: p, index: last)!.tracks.map(\.id), p.tracks.dropLast().map(\.id))
    }

    func testOutOfRangeAndLastLayerAreRefused() {
        let p = sample()
        XCTAssertNil(LayerEditing.delete(in: p, index: -1))
        XCTAssertNil(LayerEditing.delete(in: p, index: p.tracks.count))
        var one = Project.new(); one.tracks = [Track(name: "だけ")]
        XCTAssertNil(LayerEditing.delete(in: one, index: 0))
        XCTAssertEqual(LayerEditing.deleteBlockedReason(in: one, index: 0), "最後のレイヤーは削除できません")
        XCTAssertNotNil(LayerEditing.deleteBlockedReason(in: p, index: 99))
        XCTAssertNil(LayerEditing.deleteBlockedReason(in: p, index: 0))
    }

    func testLockedLayerIsDeletedByTheCoreFunction() {
        let p = sample()
        let q = LayerEditing.delete(in: p, index: 2)!
        XCTAssertFalse(q.allClips.contains { $0.id == "d" })
        XCTAssertTrue(LayerEditing.deletionImpact(in: p, index: 2)!.locked)
        XCTAssertEqual(LayerEditing.deletionImpact(in: p, index: 0)!.clipCount, 2)
        XCTAssertNil(LayerEditing.deletionImpact(in: p, index: 50))
    }

    func testDeleteKeepsCompoundsMarkersAndSubtitleNames() {
        var p = Project.new()
        var comp = Clip(); comp.id = "comp"; comp.type = .compound; comp.start = 0; comp.duration = 3
        var inner = Track(name: "中"); inner.clips = [clip("child")]
        comp.tracks = [inner]
        p.tracks[1].clips = [comp]
        p.tracks[3].name = SubtitleFile.layerName
        p.tracks[4].name = "\(SubtitleFile.layerName) 2"
        p.markers = [Marker(time: 1, name: "m")]
        let q = LayerEditing.delete(in: p, index: 3)!
        XCTAssertEqual(q.markers, p.markers)
        XCTAssertEqual(q.tracks.last?.name, "字幕 2")
        XCTAssertTrue(SubtitleFile.isSubtitleLayer(q.tracks.last!.name))
        XCTAssertEqual(q.tracks[1].clips.first?.tracks?.first?.clips.first?.id, "child", "複合の中は変わらない")
        assertNoLayerOverlaps(q)
        // 複合を含むレイヤーを消すと、中身ごと消える(ほかに参照は残らない)
        let r = LayerEditing.delete(in: p, index: 1)!
        XCTAssertFalse(r.allClips.contains { $0.id == "comp" })
        assertNoLayerOverlaps(r)
        XCTAssertEqual(Set(r.tracks.map(\.id)).count, r.tracks.count, "layer id は重ならない")
    }

    func testDeletedProjectRoundTripsByteIdentical() throws {
        let q = LayerEditing.delete(in: sample(), index: 1)!
        let a = try q.encoded()
        let b = try Project.decode(from: a).encoded()
        XCTAssertEqual(a, b)
    }
}
