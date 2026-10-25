import XCTest
@testable import MovieCutCore

/// M7: クリップメニュー(複製・切り落とし・すき間を詰めて削除・前後選択・レイヤー移動)と移動メニュー(編集点・セリフ・時間指定)の純粋な計算。
final class MenuEditingTests: XCTestCase {
    private func clip(_ id: String, _ type: ClipType, start: Double, dur: Double, offset: Double = 0, srcDur: Double? = nil) -> Clip {
        var c = Clip()
        c.id = id; c.type = type; c.start = start; c.duration = dur; c.offset = offset; c.srcDuration = srcDur
        return c
    }

    /// 3 レイヤー。T0: a(2〜4, 動画, offset 1) と b(4〜6, 画像) と c(8〜10, 文字) / T1: d(5〜6, 音声) / T2: 空
    private func sample() -> Project {
        var p = Project()
        p.tracks = [Track(name: "1"), Track(name: "2"), Track(name: "3")]
        p.tracks[0].clips = [clip("a", .video, start: 2, dur: 2, offset: 1, srcDur: 10), clip("b", .image, start: 4, dur: 2), clip("c", .text, start: 8, dur: 2)]
        p.tracks[1].clips = [clip("d", .audio, start: 5, dur: 1, srcDur: 3)]
        return p
    }

    private func find(_ p: Project, _ id: String) -> Clip { p.allClips.first { $0.id == id }! }

    // MARK: 複製

    func testDuplicatePlacesCopyRightAfterOriginalOnSameLayerWithNewId() throws {
        var p = sample()
        p.tracks[0].clips[2].start = 20     // c を遠くへ(a,b の後ろを空ける)
        let r = try XCTUnwrap(ClipEditing.duplicate(in: p, clipId: "b"))
        XCTAssertNotEqual(r.newId, "b")
        let copy = find(r.project, r.newId)
        XCTAssertEqual(copy.start, 6, accuracy: 1e-9)          // b の終わり
        XCTAssertEqual(copy.duration, 2)
        XCTAssertEqual(ClipEditing.locate(r.newId, in: r.project)?.track, 0)
        XCTAssertEqual(ClipEditing.locate(r.newId, in: r.project)?.index, 2, "元のすぐ後ろに入る")
        XCTAssertEqual(r.project.allClips.count, p.allClips.count + 1)
        XCTAssertEqual(r.project.tracks.count, 3)
        XCTAssertEqual(find(r.project, "b"), find(p, "b"), "元は変わらない")
    }

    func testDuplicateKeepsEverythingElseOfTheClip() throws {
        var p = sample()
        p.tracks[0].clips[0].extra = ["k": .string("v")]
        p.tracks[0].clips[0].src = "/x/y.mp4"
        let r = try XCTUnwrap(ClipEditing.duplicate(in: p, clipId: "a"))
        var expect = find(p, "a"); expect.id = r.newId; expect.start = 4
        // a の直後(4〜6)は b と重なる → 最初の空きレイヤー(T1 の 5〜6 は d と重なる → T2)
        XCTAssertEqual(ClipEditing.locate(r.newId, in: r.project)?.track, 2)
        XCTAssertEqual(find(r.project, r.newId), expect)
    }

    func testDuplicateOverlapUsesFirstLayerWithFreeSpaceAtThatTime() throws {
        var p = sample()
        // b(4〜6) の複製は 6〜8: T0 では c(8〜10) と接するだけ → 重ならないので同じレイヤー
        let r1 = try XCTUnwrap(ClipEditing.duplicate(in: p, clipId: "b"))
        XCTAssertEqual(ClipEditing.locate(r1.newId, in: r1.project)?.track, 0)
        // c を 7〜9 に置くと T0 は埋まる → T1(d は 5〜6)が空いている
        p.tracks[0].clips[2].start = 7
        let r2 = try XCTUnwrap(ClipEditing.duplicate(in: p, clipId: "b"))
        XCTAssertEqual(ClipEditing.locate(r2.newId, in: r2.project)?.track, 1)
        XCTAssertEqual(find(r2.project, r2.newId).start, 6, accuracy: 1e-9)
    }

    func testDuplicateWithNoFreeLayerAddsOneAtTheBottom() throws {
        var p = Project()
        p.tracks = [Track(name: "1")]
        p.tracks[0].clips = [clip("x", .image, start: 0, dur: 2), clip("y", .image, start: 2, dur: 2)]
        let r = try XCTUnwrap(ClipEditing.duplicate(in: p, clipId: "x"))   // 2〜4 は y と重なり、他に層が無い
        XCTAssertEqual(r.project.tracks.count, 2)
        XCTAssertEqual(r.project.tracks[1].name, "レイヤー2")
        XCTAssertEqual(ClipEditing.locate(r.newId, in: r.project)?.track, 1)
    }

    func testDuplicateMissingClipAndZeroLength() {
        XCTAssertNil(ClipEditing.duplicate(in: sample(), clipId: "nope"))
        var p = Project()
        p.tracks = [Track(name: "1")]
        p.tracks[0].clips = [clip("z", .text, start: 1, dur: 0), clip("w", .text, start: 1, dur: 3)]
        let r = ClipEditing.duplicate(in: p, clipId: "z")
        XCTAssertEqual(r.flatMap { ClipEditing.locate($0.newId, in: $0.project)?.track }, 0, "長さ 0 は何とも重ならない")
    }

    // MARK: 切り落とし(offset の計算は左端トリム / 分割と同じ)

    func testTrimBeforeVideoAddsToOffsetAndKeepsEnd() throws {
        let p = sample()
        let q = try XCTUnwrap(ClipEditing.trimBefore(in: p, clipId: "a", at: 3))     // a: 2〜4, offset 1
        let a = find(q, "a")
        XCTAssertEqual(a.start, 3); XCTAssertEqual(a.duration, 1); XCTAssertEqual(a.offset, 2)
        XCTAssertEqual(a.start + a.duration, 4, "終わりは動かない")
    }

    func testTrimBeforeMatchesTheRightHalfOfASplit() throws {
        for type in [ClipType.video, .audio, .voice, .image, .text, .blur] {
            var p = Project()
            p.tracks = [Track(name: "1")]
            p.tracks[0].clips = [clip("x", type, start: 1.5, dur: 3, offset: 0.75, srcDur: 9)]
            let q = try XCTUnwrap(ClipEditing.trimBefore(in: p, clipId: "x", at: 2.25))
            let (_, right) = try XCTUnwrap(ClipEditing.split(p.tracks[0].clips[0], at: 2.25))
            let c = find(q, "x")
            XCTAssertEqual(c.start, right.start, accuracy: 1e-12, "\(type)")
            XCTAssertEqual(c.duration, right.duration, accuracy: 1e-12, "\(type)")
            XCTAssertEqual(c.offset, right.offset, accuracy: 1e-12, "\(type)")
        }
    }

    func testTrimBeforeLeavesOffsetAloneForImagesAndText() throws {
        let q = try XCTUnwrap(ClipEditing.trimBefore(in: sample(), clipId: "b", at: 5))   // 画像
        XCTAssertEqual(find(q, "b").offset, 0)
        XCTAssertEqual(find(q, "b").start, 5); XCTAssertEqual(find(q, "b").duration, 1)
        let r = try XCTUnwrap(ClipEditing.trimBefore(in: sample(), clipId: "c", at: 9))   // 文字
        XCTAssertEqual(find(r, "c").offset, 0)
    }

    func testTrimAfterShortensOnlyTheDuration() throws {
        let q = try XCTUnwrap(ClipEditing.trimAfter(in: sample(), clipId: "a", at: 3.5))
        let a = find(q, "a")
        XCTAssertEqual(a.start, 2); XCTAssertEqual(a.duration, 1.5); XCTAssertEqual(a.offset, 1)
    }

    func testTrimNeedsThePlayheadStrictlyInside() {
        let p = sample()   // a は 2〜4
        for t in [1.0, 2.0, 4.0, 5.0, -1.0] {
            XCTAssertNil(ClipEditing.trimBefore(in: p, clipId: "a", at: t), "t=\(t)")
            XCTAssertNil(ClipEditing.trimAfter(in: p, clipId: "a", at: t), "t=\(t)")
            XCTAssertFalse(ClipEditing.canTrim(find(p, "a"), at: t))
        }
        XCTAssertTrue(ClipEditing.canTrim(find(p, "a"), at: 2.001))
        XCTAssertTrue(ClipEditing.canTrim(find(p, "a"), at: 3.999))
        XCTAssertNil(ClipEditing.trimBefore(in: p, clipId: "nope", at: 3))
    }

    func testTrimDoesNotTouchOtherClips() throws {
        let p = sample()
        let q = try XCTUnwrap(ClipEditing.trimAfter(in: p, clipId: "b", at: 5))
        for id in ["a", "c", "d"] { XCTAssertEqual(find(q, id), find(p, id)) }
    }

    // MARK: すき間を詰めて削除

    func testRippleDeleteShiftsLaterClipsOfTheSameLayerOnly() throws {
        let p = sample()      // T0: a(2〜4) b(4〜6) c(8〜10) / T1: d(5〜6)
        let q = try XCTUnwrap(ClipEditing.rippleDelete(in: p, clipId: "b"))
        XCTAssertNil(ClipEditing.locate("b", in: q))
        XCTAssertEqual(find(q, "a").start, 2, "前のクリップは動かない")
        XCTAssertEqual(find(q, "c").start, 6, "後ろは b の長さ(2)だけ左へ")
        XCTAssertEqual(find(q, "c").duration, 2)
        XCTAssertEqual(find(q, "d"), find(p, "d"), "ほかのレイヤーは動かない")
    }

    func testRippleDeleteOfTheLastClipChangesNothingElse() throws {
        let p = sample()
        let q = try XCTUnwrap(ClipEditing.rippleDelete(in: p, clipId: "c"))
        XCTAssertEqual(q.allClips.count, p.allClips.count - 1)
        for id in ["a", "b", "d"] { XCTAssertEqual(find(q, id), find(p, id)) }
    }

    func testRippleDeleteDoesNotMoveClipsThatOverlapOrPrecede() throws {
        var p = sample()
        p.tracks[0].clips.append(clip("o", .text, start: 3, dur: 3))   // a(2〜4) と重なる(途中から始まる)クリップ
        let q = try XCTUnwrap(ClipEditing.rippleDelete(in: p, clipId: "a"))
        XCTAssertEqual(find(q, "o").start, 3, "消したクリップにかかっていたものは動かさない")
        XCTAssertEqual(find(q, "b").start, 2, "終わり以降に始まるものは詰める")
        XCTAssertEqual(find(q, "c").start, 6)
    }

    func testRippleDeleteNeverGoesBelowZeroAndMissingIsNil() throws {
        var p = Project()
        p.tracks = [Track(name: "1")]
        p.tracks[0].clips = [clip("x", .image, start: 0, dur: 3), clip("y", .image, start: 3, dur: 1)]
        let q = try XCTUnwrap(ClipEditing.rippleDelete(in: p, clipId: "x"))
        XCTAssertEqual(find(q, "y").start, 0)
        XCTAssertNil(ClipEditing.rippleDelete(in: p, clipId: "nope"))
    }

    // MARK: 前後のクリップ

    func testAdjacentClipOrderIsByStartTimeAcrossLayers() {
        let p = sample()   // 開始順: a(2) b(4) d(5) c(8)
        XCTAssertEqual(ClipEditing.clipsByStart(p).map(\.id), ["a", "b", "d", "c"])
        XCTAssertEqual(ClipEditing.adjacentClipId(in: p, from: "b", forward: true, playhead: 0), "d")
        XCTAssertEqual(ClipEditing.adjacentClipId(in: p, from: "d", forward: false, playhead: 0), "b")
        XCTAssertEqual(ClipEditing.adjacentClipId(in: p, from: "c", forward: true, playhead: 0), nil, "最後")
        XCTAssertEqual(ClipEditing.adjacentClipId(in: p, from: "a", forward: false, playhead: 0), nil, "最初")
    }

    func testSameStartIsOrderedByLayerThenIndex() {
        var p = Project()
        p.tracks = [Track(name: "1"), Track(name: "2")]
        p.tracks[0].clips = [clip("p", .text, start: 1, dur: 1), clip("q", .text, start: 1, dur: 1)]
        p.tracks[1].clips = [clip("r", .text, start: 1, dur: 1)]
        XCTAssertEqual(ClipEditing.clipsByStart(p).map(\.id), ["p", "q", "r"])
    }

    func testAdjacentWithoutSelectionUsesPlayhead() {
        let p = sample()
        XCTAssertEqual(ClipEditing.adjacentClipId(in: p, from: nil, forward: true, playhead: 4.5), "d")
        XCTAssertEqual(ClipEditing.adjacentClipId(in: p, from: nil, forward: true, playhead: 4), "b", "同じ時刻の頭は含む")
        XCTAssertEqual(ClipEditing.adjacentClipId(in: p, from: nil, forward: false, playhead: 4.5), "b")
        XCTAssertNil(ClipEditing.adjacentClipId(in: p, from: nil, forward: true, playhead: 9))
        XCTAssertNil(ClipEditing.adjacentClipId(in: p, from: nil, forward: false, playhead: 1))
    }

    func testHasAdjacentClipAgreesWithAdjacentClipId() {
        let p = sample()
        for sel in [nil, "a", "b", "c", "d", "ghost"] as [String?] {
            for forward in [true, false] {
                for t in [0.0, 2.0, 4.5, 8.0, 12.0] {
                    XCTAssertEqual(ClipEditing.hasAdjacentClip(in: p, from: sel, forward: forward, playhead: t),
                                   ClipEditing.adjacentClipId(in: p, from: sel, forward: forward, playhead: t) != nil, "sel=\(sel ?? "-") fwd=\(forward) t=\(t)")
                }
            }
        }
    }

    // MARK: レイヤー移動

    func testMoveToAdjacentLayerKeepsTimeAndCreatesNoLayer() throws {
        let p = sample()
        let down = try XCTUnwrap(ClipEditing.moveToAdjacentLayer(in: p, clipId: "b", delta: 1))
        XCTAssertEqual(ClipEditing.locate("b", in: down)?.track, 1)
        XCTAssertEqual(find(down, "b"), find(p, "b"), "時刻も中身も同じ")
        XCTAssertEqual(down.tracks.count, 3)
        let up = try XCTUnwrap(ClipEditing.moveToAdjacentLayer(in: down, clipId: "b", delta: -1))
        XCTAssertEqual(ClipEditing.locate("b", in: up)?.track, 0)
    }

    func testMoveToAdjacentLayerStopsAtTheEnds() {
        let p = sample()
        XCTAssertNil(ClipEditing.moveToAdjacentLayer(in: p, clipId: "a", delta: -1), "一番上の行")
        var q = p
        q.tracks[2].clips = [clip("z", .text, start: 0, dur: 1)]
        XCTAssertNil(ClipEditing.moveToAdjacentLayer(in: q, clipId: "z", delta: 1), "一番下の行")
        XCTAssertNil(ClipEditing.moveToAdjacentLayer(in: p, clipId: "a", delta: 0))
        XCTAssertNil(ClipEditing.moveToAdjacentLayer(in: p, clipId: "nope", delta: 1))
    }

    // MARK: 編集点・セリフ

    func testEditPointsIncludeZeroEndAndEveryClipEdgeOfAllLayers() {
        XCTAssertEqual(ClipEditing.editPoints(sample()), [0, 2, 4, 5, 6, 8, 10])
        XCTAssertEqual(ClipEditing.editPoints(Project()), [0])
    }

    func testPreviousAndNextPointSkipTheCurrentPosition() {
        let pts = ClipEditing.editPoints(sample())
        XCTAssertEqual(ClipEditing.nextPoint(pts, after: 4), 5)
        XCTAssertEqual(ClipEditing.previousPoint(pts, before: 4), 2)
        XCTAssertEqual(ClipEditing.nextPoint(pts, after: 4.0000001), 5, "ほぼ同じ時刻は同じ点とみなす")
        XCTAssertNil(ClipEditing.nextPoint(pts, after: 10))
        XCTAssertNil(ClipEditing.previousPoint(pts, before: 0))
        XCTAssertEqual(ClipEditing.previousPoint(pts, before: 100), 10)
        XCTAssertEqual(ClipEditing.nextPoint(pts, after: -5), 0)
    }

    func testHasEditPointMatchesPoints() {
        let p = sample()
        let pts = ClipEditing.editPoints(p)
        for t in [-1.0, 0, 3, 10, 11] {
            XCTAssertEqual(ClipEditing.hasEditPoint(p, before: t), ClipEditing.previousPoint(pts, before: t) != nil, "t=\(t)")
            XCTAssertEqual(ClipEditing.hasEditPoint(p, after: t), ClipEditing.nextPoint(pts, after: t) != nil, "t=\(t)")
        }
    }

    func testVoiceStartsOnlyUseVoiceClips() {
        var p = sample()
        p.tracks[2].clips = [clip("v1", .voice, start: 3, dur: 1), clip("v2", .voice, start: 7, dur: 1)]
        p.tracks[1].clips.append(clip("v3", .voice, start: 3, dur: 2))   // 同じ頭は 1 つに
        XCTAssertEqual(ClipEditing.voiceStarts(p), [3, 7])
        XCTAssertEqual(ClipEditing.voiceStarts(Project()), [])
    }

    // MARK: 時間の読み取り

    func testParseTimecodeAcceptedForms() {
        let cases: [(String, Double)] = [
            ("12.5", 12.5), ("0", 0), ("90", 90), (".5", 0.5), ("1:23", 83), ("1:23.5", 83.5), ("00:01:23.50", 83.5),
            ("0:00.25", 0.25), ("1:00:00", 3600), ("00:04.68", 4.68), (" 2:05 ", 125), ("１２．５", 12.5), ("1：23", 83), ("10:00", 600),
        ]
        for (s, v) in cases { XCTAssertEqual(ClipEditing.parseTimecode(s) ?? .nan, v, accuracy: 1e-9, s) }
    }

    func testParseTimecodeRejectsGarbage() {
        for s in ["", "  ", "abc", "-5", "1:2:3:4", "1::2", ":30", "1:", "1:75", "1:60", "1:61:00", "1.5:30", "1e3", "1,5", "12.5.1", "--", "∞", "nan"] {
            XCTAssertNil(ClipEditing.parseTimecode(s), "「\(s)」は読めないはず")
        }
    }

    func testClampJump() {
        XCTAssertEqual(ClipEditing.clampJump(-3, end: 10), 0)
        XCTAssertEqual(ClipEditing.clampJump(99, end: 10), 10)
        XCTAssertEqual(ClipEditing.clampJump(4, end: 10), 4)
        XCTAssertEqual(ClipEditing.clampJump(4, end: 0), 0)
    }
}
