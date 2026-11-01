import XCTest
@testable import MovieCutCore

/// 1 コマ移動(ClipNudge): fps 単位、頭は 0 で止まる、ロックされたレイヤーは動かさない、重なりは禁止しない、何も変わらなければ nil。
final class ClipNudgeTests: XCTestCase {
    private func clip(_ id: String, start: Double, duration: Double = 2) -> Clip {
        var c = Clip(); c.id = id; c.type = .text; c.start = start; c.duration = duration; c.text = id; return c
    }

    private func project(_ layers: [(name: String, clips: [Clip], locked: Bool)], fps: Double = 60) -> Project {
        var p = Project(); p.fps = fps
        p.tracks = layers.map { l in var t = Track(name: l.name); t.clips = l.clips; if l.locked { t.locked = true }; return t }
        return p
    }

    private func start(_ id: String, in p: Project) -> Double? { p.allClips.first { $0.id == id }?.start }

    func testOneFrameForwardAtSixtyFps() throws {
        let p = project([("L1", [clip("a", start: 1)], false)])
        let r = try XCTUnwrap(ClipNudge.nudge(in: p, clipIds: ["a"], frames: 1))
        XCTAssertEqual(try XCTUnwrap(start("a", in: r)), 1 + 1.0 / 60, accuracy: 1e-9)
    }

    func testFrameLengthFollowsProjectFps() throws {
        let p = project([("L1", [clip("a", start: 1)], false)], fps: 30)
        let r = try XCTUnwrap(ClipNudge.nudge(in: p, clipIds: ["a"], frames: -2))
        XCTAssertEqual(try XCTUnwrap(start("a", in: r)), 1 - 2.0 / 30, accuracy: 1e-9)
    }

    func testStartStopsAtZeroAndNoChangeIsNil() {
        let p = project([("L1", [clip("a", start: 0)], false)])
        XCTAssertNil(ClipNudge.nudge(in: p, clipIds: ["a"], frames: -1), "頭が 0 のクリップは前へ動かせない")
        XCTAssertNil(ClipNudge.nudge(in: p, clipIds: ["a"], frames: 0))
        XCTAssertNil(ClipNudge.nudge(in: p, clipIds: ["missing"], frames: 1))
    }

    func testMultiSelectionKeepsRelativePositionsAndClampsAtZero() throws {
        // 2 つ選び、後ろ(0.5 秒)を前へ 1 秒動かそうとすると、頭 0 で全体が止まる
        let p = project([("L1", [clip("a", start: 0.5)], false), ("L2", [clip("b", start: 1.5)], false)])
        let r = try XCTUnwrap(ClipNudge.nudge(in: p, clipIds: ["a", "b"], frames: -60))
        XCTAssertEqual(try XCTUnwrap(start("a", in: r)), 0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(start("b", in: r)), 1, accuracy: 1e-9)
    }

    func testLockedLayerClipIsNotMoved() throws {
        let p = project([("ロック", [clip("locked", start: 3)], true), ("L2", [clip("free", start: 3)], false)])
        let r = try XCTUnwrap(ClipNudge.nudge(in: p, clipIds: ["locked", "free"], frames: 1))
        XCTAssertEqual(start("locked", in: r), 3, "ロックされたレイヤーのクリップは動かさない")
        XCTAssertEqual(try XCTUnwrap(start("free", in: r)), 3 + 1.0 / 60, accuracy: 1e-9)
        XCTAssertNil(ClipNudge.nudge(in: p, clipIds: ["locked"], frames: 1), "ロックだけなら何も変わらない")
    }

    func testOverlapIsAllowedLikeDrag() throws {
        let p = project([("L1", [clip("a", start: 1)], false), ("L2", [clip("b", start: 1 + 1.0 / 60)], false)])
        let r = try XCTUnwrap(ClipNudge.nudge(in: p, clipIds: ["a"], frames: 1))
        XCTAssertEqual(r.allClips.count, 2)
        XCTAssertEqual(try XCTUnwrap(start("a", in: r)), start("b", in: r) ?? -1, accuracy: 1e-9, "重なりは禁止しない")
    }
}
