import XCTest
@testable import MovieCutCore

/// 2026-11-02 不具合: 5 レイヤー・20 素材を一度に追加すると、全部が同じ時刻に置かれ、満杯のあふれは 0 番に重なった。
final class BulkAddOverlapTests: XCTestCase {
    private func fiveLayers() -> Project {
        var p = Project()
        p.tracks = (1...5).map { Track(name: "レイヤー\($0)") }
        return p
    }

    func testBulkAdd20ToFiveLayersNeverOverlaps() {
        var p = fiveLayers()
        let media = (0..<20).map { ("/\($0).png", ClipType.image, 5.0) }
        let ids = ClipEditing.place(media: media, at: 3, in: &p)
        XCTAssertEqual(ids.count, 20)
        assertNoLayerOverlaps(p)
        // 順番に、直前の終わりから
        let starts = ids.map { id in p.allClips.first { $0.id == id }!.start }
        XCTAssertEqual(starts.first, 3)
        for i in 1..<starts.count { XCTAssertEqual(starts[i], starts[i - 1] + 5, accuracy: 1e-9) }
    }

    func testBulkAddIntoOccupiedProjectSpillsAndNeverOverlaps() {
        var p = fiveLayers()
        for t in 0..<5 {
            var c = Clip(); c.type = .image; c.src = "/x.png"; c.start = Double(t); c.duration = 30
            p.tracks[t].clips = [c]
        }
        p.tracks[1].locked = true
        let media = (0..<20).map { ("/\($0).mp4", ClipType.video, Double($0 % 4 + 1)) }
        _ = ClipEditing.place(media: media, at: 0, in: &p)
        assertNoLayerOverlaps(p)
        XCTAssertEqual(p.tracks[1].clips.count, 1, "ロックのレイヤーには置かない")
    }

    func testSingleAddWhenAllLayersBusyAddsLayer() {
        var p = fiveLayers()
        for t in 0..<5 { var c = Clip(); c.type = .image; c.start = 0; c.duration = 10; p.tracks[t].clips = [c] }
        _ = ClipEditing.place(media: [("/a.png", .image, 5)], at: 2, in: &p)
        XCTAssertEqual(p.tracks.count, 6)
        assertNoLayerOverlaps(p)
    }

    func testPasteIntoOccupiedSpotNeverOverlaps() {
        var p = fiveLayers()
        var c = Clip(); c.type = .image; c.start = 0; c.duration = 5
        p.tracks[0].clips = [c]
        let clip = ClipClipboard.make(from: p, clipIds: [c.id])!
        var q = p
        for _ in 0..<8 {
            q = ClipEditing.paste(clip, in: q, at: 1, targetTrack: 0)!.project
        }
        assertNoLayerOverlaps(q)
        XCTAssertEqual(q.allClips.count, 9)
    }
}
