import XCTest
@testable import MovieCutCore

/// クリップ単位のロック: ファイル形式(true のときだけ書く)と、レイヤーのロックと共通のガード。
final class ClipLockTests: XCTestCase {
    private func clip(_ id: String, start: Double, dur: Double) -> Clip {
        var c = Clip(); c.id = id; c.type = .image; c.start = start; c.duration = dur
        return c
    }
    private func sample() -> Project {
        var p = Project.new()
        p.tracks[0].clips = [clip("a", start: 0, dur: 2), clip("b", start: 3, dur: 2)]
        p.tracks[1].clips = [clip("d", start: 0, dur: 2)]
        return p
    }
    private func fixtureURL(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "ymproj", subdirectory: "Fixtures"))
    }

    func testOmittedWhenFalseAndWrittenWhenTrue() throws {
        let base = sample()
        var p = base
        XCTAssertFalse(String(decoding: try p.encoded(), as: UTF8.self).contains("\"locked\""))
        p = try XCTUnwrap(LayerEditing.setClipsLocked(in: p, ids: ["a"], true))
        let json = String(decoding: try p.encoded(), as: UTF8.self)
        XCTAssertEqual(json.components(separatedBy: "\"locked\"").count - 1, 1)
        let back = try Project.decode(from: try p.encoded())
        XCTAssertEqual(back.tracks[0].clips[0].locked, true)
        XCTAssertNil(back.tracks[0].clips[1].locked)
        XCTAssertEqual(try back.encoded(), try p.encoded())
        // 解除すれば元のファイルと同じ
        let q = try XCTUnwrap(LayerEditing.setClipsLocked(in: p, ids: ["a"], false))
        XCTAssertEqual(try q.encoded(), try base.encoded())
        XCTAssertNil(LayerEditing.setClipsLocked(in: q, ids: ["a"], false), "変化なしは nil")
    }

    func testOldFixturesRoundTripWithoutLockedKey() throws {
        for name in ["rich", "timeline", "transitions", "effects", "keyframes"] {
            let data = try Data(contentsOf: fixtureURL(name))
            let p = try Project.decode(from: data)
            XCTAssertFalse(String(decoding: try p.encoded(), as: UTF8.self).contains("\"locked\"") && !String(decoding: data, as: UTF8.self).contains("\"locked\""), name)
            XCTAssertEqual(try Project.decode(from: try p.encoded()).encoded(), try p.encoded(), name)
        }
    }

    func testGuardRefusesMoveTrimSplitDeleteOnLockedClipAndAllowsUnlock() throws {
        let p = try XCTUnwrap(LayerEditing.setClipsLocked(in: sample(), ids: ["a"], true))
        func moved() -> Project { var q = p; q.tracks[0].clips[0].start = 1; return q }
        func trimmed() -> Project { var q = p; q.tracks[0].clips[0].duration = 1; return q }
        let split = ClipEditing.split(in: p, clipId: "a", at: 1)!.project
        let deleted = ClipEditing.delete(in: p, clipId: "a")!
        var otherLayer = p; otherLayer.tracks[1].clips.append(otherLayer.tracks[0].clips.removeFirst())
        for (n, q) in [("move", moved()), ("trim", trimmed()), ("split", split), ("delete", deleted), ("layer", otherLayer)] {
            XCTAssertTrue(LayerEditing.violatesLock(old: p, new: q), n)
        }
        // ほかのクリップは自由、ロックの切り替え自体は通る
        var free = p; free.tracks[0].clips[1].start = 9
        XCTAssertFalse(LayerEditing.violatesLock(old: p, new: free))
        let unlocked = try XCTUnwrap(LayerEditing.setClipsLocked(in: p, ids: ["a"], false))
        XCTAssertFalse(LayerEditing.violatesLock(old: p, new: unlocked))
        // 解除すれば動かせる
        var m = unlocked; m.tracks[0].clips[0].start = 1
        XCTAssertFalse(LayerEditing.violatesLock(old: unlocked, new: m))
        // editable / isLockedClip もクリップのロックを見る
        XCTAssertEqual(LayerEditing.editableIds(["a", "b", "d"], in: p), ["b", "d"])
        XCTAssertTrue(LayerEditing.isLockedClip("a", in: p)); XCTAssertFalse(LayerEditing.isLockedClip("b", in: p))
        XCTAssertNil(ClipNudge.nudge(in: p, clipIds: ["a"], frames: 1))
        XCTAssertTrue(LayerEditing.allClipsLocked(["a"], in: p))
        XCTAssertFalse(LayerEditing.allClipsLocked(["a", "b"], in: p))
    }
}
