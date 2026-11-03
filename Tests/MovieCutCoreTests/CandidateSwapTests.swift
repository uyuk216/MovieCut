import XCTest
@testable import MovieCutCore

/// 候補クリップの比較・差し替え(候補 36)。
final class CandidateSwapTests: XCTestCase {
    private func video(_ id: String = "v", src: String = "/m/a.mov") -> Clip {
        var c = Clip(); c.id = id; c.type = .video; c.src = src; c.srcDuration = 20; c.start = 2; c.duration = 6; c.offset = 3
        c.opacity = 0.5; c.effects = [Effect(.sepia)]; c.fadeIn = 0.5
        return c
    }

    func testCandidatesAreSameKindDedupedAndOrdered() {
        var p = Project()
        p.mediaPool = ["/m/b.mov", "/m/pic.png", "/m/a.mov", "/m/c.mp4", "/m/b.mov"]
        var other = video("o", src: "/m/d.mov")
        var inner = video("i", src: "/m/e.mov")
        var comp = Clip(); comp.id = "comp"; comp.type = .compound
        var kt = Track(name: "中"); kt.clips = [inner]; comp.tracks = [kt]
        other.start = 20
        p.tracks[0].clips = [video(), other, comp]
        inner.src = nil
        let c = CandidateSwap.candidates(for: video(), in: p, extra: ["/m/x.mov", "/m/c.mp4", "/m/y.png"])
        XCTAssertEqual(c.map(\.path), ["/m/b.mov", "/m/c.mp4", "/m/d.mov", "/m/e.mov", "/m/x.mov"])
        XCTAssertTrue(c.allSatisfy { $0.kind == .video })
    }

    func testUnsupportedClipsHaveNoCandidates() {
        var p = Project(); p.mediaPool = ["/m/b.mov"]
        var f = video(); f.freeze = true
        var l = video(); l.locked = true
        var t = Clip(); t.type = .text
        for c in [f, l, t] { XCTAssertTrue(CandidateSwap.candidates(for: c, in: p).isEmpty) }
        XCTAssertFalse(CandidateSwap.supports(video(src: "")))
    }

    func testSwapKeepsSettingsAndResetsOffset() throws {
        let c = video()
        let n = try XCTUnwrap(CandidateSwap.swapped(c, to: .init(path: "/m/b.mov", kind: .video), sourceDuration: 30))
        XCTAssertEqual(n.src, "/m/b.mov")
        XCTAssertEqual(n.offset, 0); XCTAssertEqual(n.srcDuration, 30)
        XCTAssertEqual(n.start, 2); XCTAssertEqual(n.duration, 6)
        XCTAssertEqual(n.opacity, 0.5); XCTAssertEqual(n.effects, c.effects); XCTAssertEqual(n.fadeIn, 0.5)
        XCTAssertEqual(n.id, c.id)
    }

    func testShortSourceTrimsDurationConsideringSpeed() throws {
        var c = video(); c.speed = 2
        let n = try XCTUnwrap(CandidateSwap.swapped(c, to: .init(path: "/m/b.mov", kind: .video), sourceDuration: 8))
        XCTAssertEqual(n.duration, 4, accuracy: 1e-9, "素材 8 秒を 2 倍速で使うと 4 秒")
        var ramp = video(); ramp.speedRamp = [SpeedKey(t: 0, v: 1), SpeedKey(t: 6, v: 2)]
        XCTAssertEqual(CandidateSwap.swapped(ramp, to: .init(path: "/m/b.mov", kind: .video), sourceDuration: 1)?.duration, 6, "速度ランプは長さを変えない")
        XCTAssertEqual(CandidateSwap.swapped(c, to: .init(path: "/m/b.mov", kind: .video), sourceDuration: 0.001)?.duration, ClipEditing.minDuration)
        XCTAssertEqual(CandidateSwap.swapped(c, to: .init(path: "/m/b.mov", kind: .video), sourceDuration: nil)?.srcDuration, 20, "測れなければ元の値のまま")
    }

    func testImageSwapClearsSrcDurationAndRefusals() throws {
        var i = Clip(); i.id = "i"; i.type = .image; i.src = "/m/a.png"; i.duration = 3
        let n = try XCTUnwrap(CandidateSwap.swapped(i, to: .init(path: "/m/b.png", kind: .image), sourceDuration: nil))
        XCTAssertNil(n.srcDuration); XCTAssertEqual(n.duration, 3)
        XCTAssertNil(CandidateSwap.swapped(i, to: .init(path: "/m/a.png", kind: .image), sourceDuration: nil), "同じ素材")
        XCTAssertNil(CandidateSwap.swapped(i, to: .init(path: "/m/b.mov", kind: .video), sourceDuration: 5), "種類が違う")
    }

    func testSwapInProjectOnlyTouchesTheClip() throws {
        var p = Project(); p.tracks[1].clips = [video(), video("w", src: "/m/z.mov")]
        let r = try XCTUnwrap(CandidateSwap.swap(in: p, clipId: "w", to: .init(path: "/m/b.mov", kind: .video), sourceDuration: 20))
        XCTAssertEqual(r.tracks[1].clips.map(\.src), ["/m/a.mov", "/m/b.mov"])
        XCTAssertNil(CandidateSwap.swap(in: p, clipId: "none", to: .init(path: "/m/b.mov", kind: .video), sourceDuration: 20))
    }
}
