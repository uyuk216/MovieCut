import XCTest
@testable import MovieCutCore

/// 機能追加後の掃除(2026-11-02): 自動で置く先がロックされたレイヤーにならないこと。
final class FeatureSweepTests: XCTestCase {
    private func clip(_ id: String, start: Double, dur: Double) -> Clip {
        var c = Clip(); c.id = id; c.type = .image; c.src = "/nonexistent/x.png"; c.start = start; c.duration = dur
        return c
    }

    /// レイヤー 0: a(0〜4)・b(4〜8)(a の後ろは b で詰まっている)、レイヤー 1: 空でロック。
    private func project() -> Project {
        var t0 = Track(name: "映像")
        t0.clips = [clip("a", start: 0, dur: 4), clip("b", start: 4, dur: 4)]
        var t1 = Track(name: "ロック")
        t1.locked = true
        var p = Project()
        p.tracks = [t0, t1]
        return p
    }

    /// 複製は、ロックされたレイヤーには置かない(空いていてもロックなら次の候補へ、無ければ新しいレイヤー)。
    func testDuplicateNeverLandsOnLockedLayer() throws {
        let r = try XCTUnwrap(ClipEditing.duplicate(in: project(), clipId: "a"))
        let placed = try XCTUnwrap(r.project.tracks.firstIndex { $0.clips.contains { $0.id == r.newId } })
        XCTAssertFalse(r.project.tracks[placed].isLocked, "ロックされたレイヤーに複製が置かれた")
        XCTAssertEqual(r.project.tracks[1].clips.count, 0, "ロックされたレイヤーの中身が変わった")
    }
}
