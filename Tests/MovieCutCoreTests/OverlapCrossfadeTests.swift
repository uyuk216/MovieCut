import XCTest
@testable import MovieCutCore

/// ずらして重ねる自動配置(X-1): 選んだクリップを前へずらして前のクリップと重ね、その重なりでクロスフェードにする。
/// 長さ・offset は変えず、後ろのクリップも動かさない。
final class OverlapCrossfadeTests: XCTestCase {
    // MARK: 道具

    private func clip(_ id: String, _ start: Double, _ dur: Double, type: ClipType = .text) -> Clip {
        var c = Clip(); c.id = id; c.type = type; c.start = start; c.duration = dur; return c
    }

    private func project(_ clips: [Clip]) -> Project {
        var p = Project()
        var t = Track(name: "t"); t.clips = clips
        p.tracks = [t]
        return p
    }

    private func applied(_ r: TransitionEditing.OverlapCrossfadeResult) throws -> (Project, Double, Double) {
        guard case .applied(let p, let secs, let shifted) = r else { XCTFail("applied でない: \(r)"); throw XCTSkip() }
        return (p, secs, shifted)
    }

    // MARK: 基本

    func testShiftsClipToOverlapPrevious() throws {
        let p = project([clip("A", 1, 4), clip("B", 6, 4), clip("C", 12, 2)])
        let (r, secs, shifted) = try applied(TransitionEditing.overlapCrossfade(in: p, clipId: "B"))
        XCTAssertEqual(secs, 0.5)
        XCTAssertEqual(shifted, 0.5)
        let b = r.tracks[0].clips[1]
        XCTAssertEqual(b.start, 5.5)                                              // 前へずらして A(〜5)と 0.5 秒重なる
        XCTAssertEqual(b.duration, 4)                                             // 長さは変えない
        XCTAssertEqual(b.offset, 0)                                               // 素材の頭も変えない
        XCTAssertEqual(b.transitionIn?.kind, "fade")
        XCTAssertEqual(b.transitionIn?.duration, 0.5)
        XCTAssertEqual(r.tracks[0].clips[0].start, 1)                             // 前のクリップは動かない
        XCTAssertEqual(r.tracks[0].clips[2].start, 12)                            // 後ろのクリップも動かない
    }

    func testAlreadyOverlappingJustSetsFade() throws {
        let p = project([clip("A", 0, 4), clip("B", 3.5, 4)])
        let (r, secs, shifted) = try applied(TransitionEditing.overlapCrossfade(in: p, clipId: "B"))
        XCTAssertEqual(shifted, 0)
        XCTAssertEqual(secs, 0.5)
        XCTAssertEqual(r.tracks[0].clips[1].start, 3.5)
        XCTAssertEqual(r.tracks[0].clips[1].transitionIn?.duration, 0.5)
    }

    func testDurationClampedByClipHalf() throws {
        let p = project([clip("A", 0, 5), clip("B", 6, 1)])
        let (r, secs, _) = try applied(TransitionEditing.overlapCrossfade(in: p, clipId: "B", duration: 2))
        XCTAssertEqual(secs, 0.5)                                                 // クリップの半分(0.5)まで
        XCTAssertEqual(r.tracks[0].clips[1].start, 5.5)
    }

    func testShiftLimitedByPreviousClipLength() throws {
        // 前のクリップが短い(0.6 秒): 重なりは前のクリップの長さまで
        let p = project([clip("A", 5, 0.6), clip("B", 7, 4)])
        let (r, secs, shifted) = try applied(TransitionEditing.overlapCrossfade(in: p, clipId: "B", duration: 2))
        XCTAssertEqual(secs, 0.6)
        XCTAssertEqual(shifted, 0.6)
        XCTAssertEqual(r.tracks[0].clips[1].start, 6.4)
        XCTAssertGreaterThanOrEqual(r.tracks[0].clips[1].start, 5)                // 前のクリップの頭より前へは出ない
    }

    // MARK: できない場合

    func testNoPreviousClip() {
        let p = project([clip("B", 6, 4)])
        XCTAssertEqual(TransitionEditing.overlapCrossfade(in: p, clipId: "B"), .noPreviousClip)
    }

    func testNotSupported() {
        let p = project([clip("A", 0, 4), clip("B", 6, 4, type: .audio)])
        XCTAssertEqual(TransitionEditing.overlapCrossfade(in: p, clipId: "B"), .notSupported)
        let p2 = project([clip("A", 0, 4, type: .audio), clip("B", 6, 4)])
        XCTAssertEqual(TransitionEditing.overlapCrossfade(in: p2, clipId: "B"), .notSupported)
    }

    func testLocked() {
        var b = clip("B", 6, 4); b.locked = true
        XCTAssertEqual(TransitionEditing.overlapCrossfade(in: project([clip("A", 0, 4), b]), clipId: "B"), .locked)
        var p = project([clip("A", 0, 4), clip("B", 6, 4)])
        p.tracks[0].locked = true
        XCTAssertEqual(TransitionEditing.overlapCrossfade(in: p, clipId: "B"), .locked)
    }

    func testNoRoomWhenPreviousTooShort() {
        // 前のクリップが 0.04 秒しかない: 最小の重なり(0.05 秒)も作れない
        let p = project([clip("A", 0, 0.04), clip("B", 0.04, 4)])
        XCTAssertEqual(TransitionEditing.overlapCrossfade(in: p, clipId: "B"), .noRoom)
    }
}
