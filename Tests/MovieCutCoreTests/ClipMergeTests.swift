import XCTest
@testable import MovieCutCore

/// 連続する同じ素材の分割点の一括統合(候補 34)。分割の逆であること。
final class ClipMergeTests: XCTestCase {
    private func video(_ id: String = "v", start: Double = 1, dur: Double = 6, offset: Double = 2) -> Clip {
        var c = Clip(); c.id = id; c.type = .video; c.src = "/nonexistent/a.mov"; c.srcDuration = 60
        c.start = start; c.duration = dur; c.offset = offset
        return c
    }

    private func project(_ clips: [Clip]) -> Project {
        var p = Project(); p.tracks[0].clips = clips; return p
    }

    /// 分割して、統合すると、元の JSON に戻る(id 以外)。
    private func assertRoundTrip(_ c: Clip, at t: Double, file: StaticString = #filePath, line: UInt = #line) throws {
        let (l, r) = try XCTUnwrap(ClipEditing.split(c, at: t), file: file, line: line)
        let m = try XCTUnwrap(ClipMerge.merged(l, r), "統合できない", file: file, line: line)
        XCTAssertEqual(try m.encodedForTest(), try c.encodedForTest(), file: file, line: line)
    }

    func testPlainVideoSplitMergesBack() throws { try assertRoundTrip(video(), at: 3.5) }

    func testSpeedAndReverseSplitMergeBack() throws {
        var c = video(); c.speed = 2
        try assertRoundTrip(c, at: 2.25)
        c.reverse = true
        try assertRoundTrip(c, at: 2.25)
        c.speed = 0.5
        try assertRoundTrip(c, at: 4)
    }

    func testAudioAndImageMergeBack() throws {
        var a = video(); a.type = .audio; a.src = "/nonexistent/a.wav"; a.volume = 0.7
        try assertRoundTrip(a, at: 2)
        var i = Clip(); i.id = "i"; i.type = .image; i.src = "/nonexistent/a.png"; i.start = 0; i.duration = 5
        try assertRoundTrip(i, at: 2)
    }

    func testKeyframesRoundTripWhenSplitFromOneClip() throws {
        var c = video()
        c.keyframes["opacity"] = [Keyframe(t: 0, v: 0), Keyframe(t: 6, v: 1)]
        c.keyframes["x"] = [Keyframe(t: 1, v: 0.2), Keyframe(t: 2, v: 0.4), Keyframe(t: 5, v: 0.9)]
        try assertRoundTrip(c, at: 3)
    }

    func testFadesAtTheOuterEdgesAreKept() throws {
        var c = video(); c.fadeIn = 0.5; c.fadeOut = 0.7
        c.transitionIn = Transition(kind: "fade", duration: 0.5)
        try assertRoundTrip(c, at: 3)
    }

    func testRefusesWhenSomethingDiffers() throws {
        let (l, r) = try XCTUnwrap(ClipEditing.split(video(), at: 3.5))
        var other = r; other.src = "/nonexistent/b.mov"
        XCTAssertNil(ClipMerge.merged(l, other), "別の素材")
        var gap = r; gap.start += 0.5
        XCTAssertNil(ClipMerge.merged(l, gap), "すき間")
        var jump = r; jump.offset += 1
        XCTAssertNil(ClipMerge.merged(l, jump), "素材の時刻が飛ぶ")
        var fx = r; fx.opacity = 0.5
        XCTAssertNil(ClipMerge.merged(l, fx), "設定が違う")
        var fast = r; fast.speed = 2
        XCTAssertNil(ClipMerge.merged(l, fast), "速度が違う")
        var tr = r; tr.transitionIn = Transition(kind: "fade", duration: 0.3)
        XCTAssertNil(ClipMerge.merged(l, tr), "つなぎ目のトランジションは消さない")
        var fo = l; fo.fadeOut = 0.4
        XCTAssertNil(ClipMerge.merged(fo, r), "つなぎ目のフェード")
        var freeze = r; freeze.freeze = true
        XCTAssertNil(ClipMerge.merged(l, freeze))
        var ramp = video(); ramp.speedRamp = [SpeedKey(t: 0, v: 1), SpeedKey(t: 6, v: 2)]
        let (rl, rr) = try XCTUnwrap(ClipEditing.split(ramp, at: 3))
        XCTAssertNil(ClipMerge.merged(rl, rr), "速度ランプは対象外")
        var voice = l; voice.type = .voice
        XCTAssertNil(ClipMerge.merged(voice, voice))
    }

    func testMergeAllCombinesRunOfThreeAndLeavesRest() throws {
        let c = video("v", start: 0, dur: 9, offset: 0)
        let (a, rest) = try XCTUnwrap(ClipEditing.split(c, at: 3))
        let (b, d) = try XCTUnwrap(ClipEditing.split(rest, at: 6))
        var unrelated = video("u", start: 20, dur: 2, offset: 0); unrelated.src = "/nonexistent/other.mov"
        let p = project([a, b, d, unrelated])
        let r = try XCTUnwrap(ClipMerge.mergeAll(in: p))
        XCTAssertEqual(r.merged, 2)
        XCTAssertEqual(r.project.tracks[0].clips.map(\.id), [a.id, "u"])
        XCTAssertEqual(r.project.tracks[0].clips[0].duration, 9, accuracy: 1e-9)
        XCTAssertEqual(r.keptIds, [a.id])
        XCTAssertNil(ClipMerge.mergeAll(in: r.project), "もう統合できるものは無い")
    }

    func testScopeAndLocks() throws {
        let c = video("v", start: 0, dur: 9, offset: 0)
        let (a, rest) = try XCTUnwrap(ClipEditing.split(c, at: 3))
        let (b, d) = try XCTUnwrap(ClipEditing.split(rest, at: 6))
        let p = project([a, b, d])
        // 末尾の 1 つだけ選ぶと、その隣との分だけ
        let r = try XCTUnwrap(ClipMerge.mergeAll(in: p, scope: [d.id]))
        XCTAssertEqual(r.merged, 1)
        XCTAssertEqual(r.project.tracks[0].clips.count, 2)
        XCTAssertNil(ClipMerge.mergeAll(in: p, scope: ["nothing"]))
        var locked = p; locked.tracks[0].locked = true
        XCTAssertNil(ClipMerge.mergeAll(in: locked))
        XCTAssertFalse(ClipMerge.hasMergeable(in: locked))
        var clipLocked = p; clipLocked.tracks[0].clips[1].locked = true
        XCTAssertNil(ClipMerge.mergeAll(in: clipLocked), "ロックされたクリップは変えない")
        XCTAssertTrue(ClipMerge.hasMergeable(in: p))
    }

    func testOnlySameLayerAndUnorderedArrayWorks() throws {
        let (a, b) = try XCTUnwrap(ClipEditing.split(video(), at: 3.5))
        var p = Project(); p.tracks[0].clips = [b, a]    // 配列の順が逆でも時刻順に見る
        XCTAssertEqual(ClipMerge.mergeAll(in: p)?.merged, 1)
        var q = Project(); q.tracks[0].clips = [a]; q.tracks[1].clips = [b]
        XCTAssertNil(ClipMerge.mergeAll(in: q), "別レイヤーはつなげない")
    }
}

private extension Clip {
    func encodedForTest() throws -> String {
        var c = self; c.id = "x"
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        return String(decoding: try e.encode(c), as: UTF8.self)
    }
}
