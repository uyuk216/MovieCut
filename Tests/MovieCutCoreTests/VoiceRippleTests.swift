import XCTest
@testable import MovieCutCore

/// 音声の作り直しで尺が変わったとき、後ろのセリフを詰める・ずらす(候補 31)。
final class VoiceRippleTests: XCTestCase {
    private func voice(_ id: String, _ start: Double, _ dur: Double) -> Clip {
        var c = Clip(); c.id = id; c.type = .voice; c.start = start; c.duration = dur; c.text = id; c.charId = "c"
        return c
    }

    private func base() -> Project {
        var p = Project()
        p.tracks[0].clips = [voice("a", 0, 2), voice("b", 2, 3), voice("c", 5, 1)]
        p.tracks[1].clips = [voice("o", 3, 1)]   // 別レイヤー
        return p
    }

    private func change(_ p: Project, _ id: String, to d: Double) -> Project {
        var q = p
        let i = q.tracks[0].clips.firstIndex { $0.id == id }!
        q.tracks[0].clips[i].duration = d
        return q
    }

    func testShorterPullsFollowingClipsLeft() {
        let old = base()
        let r = VoiceRipple.apply(old: old, new: change(old, "a", to: 1.5), changedIds: ["a"])
        XCTAssertEqual(r.project.tracks[0].clips.map(\.start), [0, 1.5, 4.5])
        XCTAssertEqual(r.shifted, 2)
        XCTAssertEqual(r.project.tracks[1].clips[0].start, 3, "他のレイヤーは動かさない")
    }

    func testLongerPushesFollowingClipsRight() {
        let old = base()
        let r = VoiceRipple.apply(old: old, new: change(old, "b", to: 4), changedIds: ["b"])
        XCTAssertEqual(r.project.tracks[0].clips.map(\.start), [0, 2, 6])
        XCTAssertEqual(r.shifted, 1)
    }

    func testCumulativeDeltasForSeveralChangedClips() {
        let old = base()
        var n = change(old, "a", to: 1)
        n = change(n, "b", to: 4)
        let r = VoiceRipple.apply(old: old, new: n, changedIds: ["a", "b"])
        // a: -1 → b は 1 に、b: +1 → c は 5 - 1 + 1 = 5
        XCTAssertEqual(r.project.tracks[0].clips.map(\.start), [0, 1, 5])
        XCTAssertEqual(r.shifted, 0, "c の変化量は −1 + 1 = 0 で動かない。尺が変わった b 自身は数えない")
    }

    func testNoChangeIsIdentity() {
        let old = base()
        let r = VoiceRipple.apply(old: old, new: old, changedIds: ["a", "b"])
        XCTAssertEqual(r.project, old)
        XCTAssertEqual(r.shifted, 0)
    }

    func testLockedClipsAndLayersAreKept() {
        var old = base()
        old.tracks[0].clips[2].locked = true
        let r = VoiceRipple.apply(old: old, new: change(old, "a", to: 1), changedIds: ["a"])
        XCTAssertEqual(r.project.tracks[0].clips.map(\.start), [0, 1, 5])
        XCTAssertEqual(r.skippedLocked, 1)
        var lockedTrack = base(); lockedTrack.tracks[0].locked = true
        let r2 = VoiceRipple.apply(old: lockedTrack, new: change(lockedTrack, "a", to: 1), changedIds: ["a"])
        XCTAssertEqual(r2.project.tracks[0].clips.map(\.start), [0, 2, 5])
        XCTAssertEqual(r2.skippedLocked, 2)
    }

    func testNeverGoesBelowZero() {
        var old = Project()
        old.tracks[0].clips = [voice("a", 0, 5), voice("b", 5.2, 1)]
        let r = VoiceRipple.apply(old: old, new: change(old, "a", to: 0.2), changedIds: ["a"])
        XCTAssertEqual(r.project.tracks[0].clips[1].start, 0.4, accuracy: 1e-9)
        var tight = old
        tight.tracks[0].clips[1].start = 5
        tight.tracks[0].clips[0].duration = 5
        let r2 = VoiceRipple.apply(old: tight, new: change(tight, "a", to: 0.1), changedIds: ["a"])
        XCTAssertGreaterThanOrEqual(r2.project.tracks[0].clips[1].start, 0)
    }

    func testClipOverlappingTheChangedOneStays() {
        var old = Project()
        old.tracks[0].clips = [voice("a", 0, 4), voice("b", 3, 1)]
        let r = VoiceRipple.apply(old: old, new: change(old, "a", to: 2), changedIds: ["a"])
        XCTAssertEqual(r.project.tracks[0].clips[1].start, 3, "終わる前に始まるクリップは動かさない")
    }
}
