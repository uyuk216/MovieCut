import XCTest
@testable import MovieCutCore

final class ClipEditingTests: XCTestCase {
    // MARK: 準備

    private func clip(_ id: String, _ type: ClipType, start: Double, dur: Double, offset: Double = 0, srcDur: Double? = nil) -> Clip {
        var c = Clip()
        c.id = id; c.type = type; c.start = start; c.duration = dur; c.offset = offset; c.srcDuration = srcDur
        return c
    }

    /// 3 レイヤー。T0: a(2〜4, 動画, offset 1, src 10) と b(8〜10, 画像) / T1: c(5〜6, 音声) / T2: 空
    private func sample() -> Project {
        var p = Project()
        p.tracks = [Track(name: "1"), Track(name: "2"), Track(name: "3")]
        p.tracks[0].clips = [clip("a", .video, start: 2, dur: 2, offset: 1, srcDur: 10), clip("b", .image, start: 8, dur: 2)]
        p.tracks[1].clips = [clip("c", .audio, start: 5, dur: 1, srcDur: 3)]
        return p
    }

    private func find(_ p: Project, _ id: String) -> Clip { p.allClips.first { $0.id == id }! }
    private func track(of id: String, _ p: Project) -> Int { ClipEditing.locate(id, in: p)!.track }

    // MARK: snapTime

    func testSnapToOtherClipEdgesZeroAndPlayhead() {
        let p = sample()
        // pps 40 なので 8pt = 0.2 秒
        XCTAssertEqual(ClipEditing.snapTime(4.1, excluding: "b", project: p, playhead: 99, pps: 40, enabled: true), 4)   // a の終わり
        XCTAssertEqual(ClipEditing.snapTime(1.9, excluding: "b", project: p, playhead: 99, pps: 40, enabled: true), 2)   // a の頭
        XCTAssertEqual(ClipEditing.snapTime(0.15, excluding: "b", project: p, playhead: 99, pps: 40, enabled: true), 0)  // 0
        XCTAssertEqual(ClipEditing.snapTime(7.05, excluding: "b", project: p, playhead: 7, pps: 40, enabled: true), 7)   // 再生ヘッド
        XCTAssertEqual(ClipEditing.snapTime(5.9, excluding: "b", project: p, playhead: 99, pps: 40, enabled: true), 6)   // c の終わり
    }

    func testSnapThresholdIsEightPointsAndScalesWithPps() {
        let p = sample()
        // 8pt ちょうど(0.2 秒 @40pps)は吸着しない、それより内側は吸着
        XCTAssertEqual(ClipEditing.snapTime(4.2, excluding: "b", project: p, playhead: 99, pps: 40, enabled: true), 4.2)
        XCTAssertEqual(ClipEditing.snapTime(4.19, excluding: "b", project: p, playhead: 99, pps: 40, enabled: true), 4)
        // 拡大すると距離(秒)は縮む: pps 400 なら 0.02 秒
        XCTAssertEqual(ClipEditing.snapTime(4.1, excluding: "b", project: p, playhead: 99, pps: 400, enabled: true), 4.1)
        XCTAssertEqual(ClipEditing.snapTime(4.01, excluding: "b", project: p, playhead: 99, pps: 400, enabled: true), 4)
    }

    func testSnapExcludesSelfAndCanBeDisabled() {
        let p = sample()
        // a 自身の端には吸着しない
        XCTAssertEqual(ClipEditing.snapTime(4.1, excluding: "a", project: p, playhead: 99, pps: 40, enabled: true), 4.1)
        XCTAssertEqual(ClipEditing.snapTime(4.1, excluding: "b", project: p, playhead: 99, pps: 40, enabled: false), 4.1)
    }

    func testSnapPicksNearestCandidate() {
        var p = Project()
        p.tracks = [Track(name: "1")]
        p.tracks[0].clips = [clip("x", .image, start: 1.0, dur: 0.1), clip("y", .image, start: 3, dur: 1)]   // 候補 1.0, 1.1
        XCTAssertEqual(ClipEditing.snapTime(1.08, excluding: "z", project: p, playhead: 99, pps: 40, enabled: true), 1.1)
    }

    // MARK: move

    func testMoveBasicAndClampAtZero() {
        let p = sample()
        let r = ClipEditing.move(in: p, clipId: "a", deltaT: 1.0, targetTrackIndex: nil, playhead: 99, pps: 40, snapEnabled: false)
        XCTAssertEqual(find(r.project, "a").start, 3, accuracy: 1e-9)
        XCTAssertEqual(find(r.project, "a").duration, 2)
        XCTAssertEqual(find(r.project, "a").offset, 1)          // 移動では offset は変わらない
        let left = ClipEditing.move(in: p, clipId: "a", deltaT: -10, targetTrackIndex: nil, playhead: 99, pps: 40, snapEnabled: false)
        XCTAssertEqual(find(left.project, "a").start, 0)
    }

    func testMoveSnapsStartEdge() {
        let p = sample()
        // a(2〜4)を +2.95 → 頭 4.95 は c の頭 5 に吸着
        let r = ClipEditing.move(in: p, clipId: "a", deltaT: 2.95, targetTrackIndex: nil, playhead: 99, pps: 40, snapEnabled: true)
        XCTAssertEqual(find(r.project, "a").start, 5, accuracy: 1e-9)
        XCTAssertEqual(r.guides, [5])
    }

    func testMoveSnapsEndEdgeAndShiftsBack() {
        let p = sample()
        // a(2〜4)を +1.95 → 頭 3.95(4 などに吸着しない: a 自身は除外、どれも遠い)、終わり 5.95 は c の終わり 6 に吸着 → 頭 4
        let r = ClipEditing.move(in: p, clipId: "a", deltaT: 1.95, targetTrackIndex: nil, playhead: 99, pps: 40, snapEnabled: true)
        XCTAssertEqual(find(r.project, "a").start, 4, accuracy: 1e-9)
        XCTAssertEqual(r.guides, [6])
    }

    func testMoveEndSnapWinsOverStartSnap() {
        var p = sample()
        p.tracks[2].clips = [clip("d", .image, start: 20, dur: 1)]
        // 頭が再生ヘッド(3)に、終わりが c の頭(5)に両方近い: 終わりが勝つ(startDrag と同じ)
        let r = ClipEditing.move(in: p, clipId: "a", deltaT: 0.95, targetTrackIndex: nil, playhead: 3, pps: 40, snapEnabled: true)
        XCTAssertEqual(find(r.project, "a").start, 3, accuracy: 1e-9)   // 頭 2.95→3 吸着、終わり 5 は c の頭に一致
        XCTAssertEqual(find(r.project, "a").start + find(r.project, "a").duration, 5, accuracy: 1e-9)
        XCTAssertEqual(Set(r.guides), [3, 5])
    }

    func testMoveToZeroAfterEndSnapNeverNegative() {
        var p = Project()
        p.tracks = [Track(name: "1"), Track(name: "2")]
        p.tracks[0].clips = [clip("m", .image, start: 3, dur: 2)]
        p.tracks[1].clips = [clip("o", .image, start: 0, dur: 1.5)]
        // 終わりが o の終わり(1.5)に吸着すると頭は -0.5 → 0 に押さえる
        let r = ClipEditing.move(in: p, clipId: "m", deltaT: -1.55, targetTrackIndex: nil, playhead: 99, pps: 40, snapEnabled: true)
        XCTAssertGreaterThanOrEqual(find(r.project, "m").start, 0)
    }

    func testCrossLayerMoveLeavesTrackAndAppends() {
        let p = sample()
        let r = ClipEditing.move(in: p, clipId: "a", deltaT: 0, targetTrackIndex: 1, playhead: 99, pps: 40, snapEnabled: false)
        XCTAssertEqual(r.project.tracks[0].clips.map(\.id), ["b"])
        XCTAssertEqual(r.project.tracks[1].clips.map(\.id), ["c", "a"])
        XCTAssertEqual(r.project.allClips.count, p.allClips.count)
        // 同じレイヤーを指す / 範囲外 / nil は動かさない(並びも変えない)
        for t in [0, 7, -1] as [Int?] + [nil] {
            let s = ClipEditing.move(in: p, clipId: "a", deltaT: 0.5, targetTrackIndex: t, playhead: 99, pps: 40, snapEnabled: false)
            XCTAssertEqual(s.project.tracks[0].clips.map(\.id), ["a", "b"])
        }
    }

    func testMoveUnknownClipIsNoOp() {
        let p = sample()
        XCTAssertEqual(ClipEditing.move(in: p, clipId: "zz", deltaT: 1, targetTrackIndex: 1, playhead: 0, pps: 40, snapEnabled: true).project, p)
    }

    // MARK: trimRight

    func testTrimRightBasicMinimumAndSnap() {
        let p = sample()
        let r = ClipEditing.trimRight(in: p, clipId: "b", deltaT: 1.0, playhead: 99, pps: 40, snapEnabled: false)
        XCTAssertEqual(find(r.project, "b").duration, 3, accuracy: 1e-9)
        XCTAssertEqual(find(r.project, "b").start, 8)
        let tiny = ClipEditing.trimRight(in: p, clipId: "b", deltaT: -5, playhead: 99, pps: 40, snapEnabled: false)
        XCTAssertEqual(find(tiny.project, "b").duration, 0.05, accuracy: 1e-9)
        // 終わり 10.95 → 再生ヘッド 11 に吸着
        let s = ClipEditing.trimRight(in: p, clipId: "b", deltaT: 0.95, playhead: 11, pps: 40, snapEnabled: true)
        XCTAssertEqual(find(s.project, "b").duration, 3, accuracy: 1e-9)
        XCTAssertEqual(s.guides, [11])
    }

    func testTrimRightSnapNeverBelowMinimum() {
        var p = sample()
        p.tracks[2].clips = [clip("n", .image, start: 8.01, dur: 1)]    // b の頭のすぐ後ろに吸着先
        let r = ClipEditing.trimRight(in: p, clipId: "b", deltaT: -1.99, playhead: 99, pps: 40, snapEnabled: true)
        XCTAssertGreaterThanOrEqual(find(r.project, "b").duration, 0.05)
    }

    func testTrimRightLimitedBySourceMinusOffsetForMedia() {
        let p = sample()
        // a は src 10・offset 1 → 長さの上限 9
        let r = ClipEditing.trimRight(in: p, clipId: "a", deltaT: 100, playhead: 99, pps: 40, snapEnabled: false)
        XCTAssertEqual(find(r.project, "a").duration, 9, accuracy: 1e-9)
        // c は src 3・offset 0 → 3
        let c = ClipEditing.trimRight(in: p, clipId: "c", deltaT: 100, playhead: 99, pps: 40, snapEnabled: false)
        XCTAssertEqual(find(c.project, "c").duration, 3, accuracy: 1e-9)
    }

    func testTrimRightImageAndTextHaveNoSourceLimit() {
        var p = sample()
        p.tracks[2].clips = [clip("t", .text, start: 0, dur: 1, srcDur: 2)]    // srcDuration があっても文字は無視
        let r = ClipEditing.trimRight(in: p, clipId: "t", deltaT: 50, playhead: 99, pps: 40, snapEnabled: false)
        XCTAssertEqual(find(r.project, "t").duration, 51, accuracy: 1e-9)
        let i = ClipEditing.trimRight(in: p, clipId: "b", deltaT: 50, playhead: 99, pps: 40, snapEnabled: false)
        XCTAssertEqual(find(i.project, "b").duration, 52, accuracy: 1e-9)
    }

    func testTrimRightWithoutSrcDurationIsUnlimited() {
        var p = sample()
        p.tracks[2].clips = [clip("v", .voice, start: 0, dur: 2)]    // ボイスは srcDuration なし
        let r = ClipEditing.trimRight(in: p, clipId: "v", deltaT: 30, playhead: 99, pps: 40, snapEnabled: false)
        XCTAssertEqual(find(r.project, "v").duration, 32, accuracy: 1e-9)
    }

    // MARK: trimLeft

    func testTrimLeftMediaMovesOffset() {
        let p = sample()
        // a(2〜4, offset 1): 左を +0.5 → 頭 2.5、長さ 1.5、offset 1.5。終わりは動かない
        let r = ClipEditing.trimLeft(in: p, clipId: "a", deltaT: 0.5, playhead: 99, pps: 40, snapEnabled: false)
        let a = find(r.project, "a")
        XCTAssertEqual(a.start, 2.5, accuracy: 1e-9)
        XCTAssertEqual(a.duration, 1.5, accuracy: 1e-9)
        XCTAssertEqual(a.offset, 1.5, accuracy: 1e-9)
        XCTAssertEqual(a.start + a.duration, 4, accuracy: 1e-9)
    }

    func testTrimLeftCannotRevealBeforeSourceStart() {
        let p = sample()
        // a の offset は 1 → 左へ 5 秒広げても 1 秒まで(頭 1、offset 0、長さ 3)
        let r = ClipEditing.trimLeft(in: p, clipId: "a", deltaT: -5, playhead: 99, pps: 40, snapEnabled: false)
        let a = find(r.project, "a")
        XCTAssertEqual(a.start, 1, accuracy: 1e-9)
        XCTAssertEqual(a.offset, 0, accuracy: 1e-9)
        XCTAssertEqual(a.duration, 3, accuracy: 1e-9)
        // offset 0 のクリップは左へ広げられない
        let c = ClipEditing.trimLeft(in: p, clipId: "c", deltaT: -2, playhead: 99, pps: 40, snapEnabled: false)
        XCTAssertEqual(find(c.project, "c").start, 5)
        XCTAssertEqual(find(c.project, "c").offset, 0)
    }

    func testTrimLeftImageTextBlurKeepOffsetUntouched() {
        var p = sample()
        var t = clip("t", .text, start: 4, dur: 3)
        t.offset = 0
        var bl = clip("bl", .blur, start: 4, dur: 3)
        bl.offset = 0
        p.tracks[2].clips = [t, bl]
        for id in ["t", "bl", "b"] {
            let r = ClipEditing.trimLeft(in: p, clipId: id, deltaT: 1.0, playhead: 99, pps: 40, snapEnabled: false)
            let c = find(r.project, id), o = find(p, id)
            XCTAssertEqual(c.offset, 0, "\(id) の offset は動かさない")
            XCTAssertEqual(c.start, o.start + 1, accuracy: 1e-9)
            XCTAssertEqual(c.duration, o.duration - 1, accuracy: 1e-9)
        }
        // 画像・文字は左へ(0 まで)広げられる。offset はそのまま 0
        let l = ClipEditing.trimLeft(in: p, clipId: "t", deltaT: -10, playhead: 99, pps: 40, snapEnabled: false)
        XCTAssertEqual(find(l.project, "t").start, 0)
        XCTAssertEqual(find(l.project, "t").duration, 7, accuracy: 1e-9)
        XCTAssertEqual(find(l.project, "t").offset, 0)
    }

    func testTrimLeftMinimumDurationAndNoNegativeStart() {
        let p = sample()
        let r = ClipEditing.trimLeft(in: p, clipId: "b", deltaT: 50, playhead: 99, pps: 40, snapEnabled: false)
        XCTAssertEqual(find(r.project, "b").duration, 0.05, accuracy: 1e-9)
        XCTAssertEqual(find(r.project, "b").start + find(r.project, "b").duration, 10, accuracy: 1e-9)
        let z = ClipEditing.trimLeft(in: p, clipId: "b", deltaT: -50, playhead: 99, pps: 40, snapEnabled: true)
        XCTAssertGreaterThanOrEqual(find(z.project, "b").start, 0)
    }

    func testTrimLeftSnapNeverBreaksMinimum() {
        var p = sample()
        // b(8〜10)。終わり直前(9.97)に吸着先があっても、長さ 0.05 を割らない
        p.tracks[2].clips = [clip("n", .image, start: 9.97, dur: 1)]
        let r = ClipEditing.trimLeft(in: p, clipId: "b", deltaT: 1.95, playhead: 99, pps: 40, snapEnabled: true)
        XCTAssertGreaterThanOrEqual(find(r.project, "b").duration, 0.05 - 1e-12)
        XCTAssertLessThanOrEqual(find(r.project, "b").start, 9.95 + 1e-9)
    }

    func testTrimLeftSnapsToNeighbour() {
        let p = sample()
        // b の頭を左へ: 8 - 1.95 = 6.05 → c の終わり 6 に吸着
        let r = ClipEditing.trimLeft(in: p, clipId: "b", deltaT: -1.95, playhead: 99, pps: 40, snapEnabled: true)
        XCTAssertEqual(find(r.project, "b").start, 6, accuracy: 1e-9)
        XCTAssertEqual(find(r.project, "b").duration, 4, accuracy: 1e-9)
        XCTAssertEqual(r.guides, [6])
    }

    func testTrimLeftOnAlreadyTinyClipDoesNotGrow() {
        var p = sample()
        p.tracks[2].clips = [clip("s", .image, start: 3, dur: 0.02)]
        let r = ClipEditing.trimLeft(in: p, clipId: "s", deltaT: 1, playhead: 99, pps: 40, snapEnabled: false)
        XCTAssertEqual(find(r.project, "s").duration, 0.02, accuracy: 1e-9)
    }

    // MARK: split

    func testSplitMediaMovesOffsetOnRight() {
        let a = clip("a", .video, start: 2, dur: 2, offset: 1, srcDur: 10)
        let (l, r) = ClipEditing.split(a, at: 3.5)!
        XCTAssertEqual(l.id, "a")
        XCTAssertEqual(l.start, 2); XCTAssertEqual(l.duration, 1.5, accuracy: 1e-9); XCTAssertEqual(l.offset, 1)
        XCTAssertNotEqual(r.id, "a")
        XCTAssertEqual(r.start, 3.5); XCTAssertEqual(r.duration, 0.5, accuracy: 1e-9); XCTAssertEqual(r.offset, 2.5, accuracy: 1e-9)
        XCTAssertEqual(r.srcDuration, 10)
        XCTAssertEqual(r.type, .video)
    }

    func testSplitImageAndTextKeepOffset() {
        for type in [ClipType.image, .text, .blur] {
            let (_, r) = ClipEditing.split(clip("x", type, start: 1, dur: 4), at: 2)!
            XCTAssertEqual(r.offset, 0, "\(type.rawValue)")
        }
    }

    func testSplitAtEdgesOrOutsideIsNil() {
        let a = clip("a", .video, start: 2, dur: 2)
        XCTAssertNil(ClipEditing.split(a, at: 2))
        XCTAssertNil(ClipEditing.split(a, at: 4))
        XCTAssertNil(ClipEditing.split(a, at: 1.99))
        XCTAssertNil(ClipEditing.split(a, at: 4.01))
        XCTAssertNotNil(ClipEditing.split(a, at: 2.0001))
    }

    func testSplitInProjectInsertsRightAfterLeft() {
        let p = sample()
        let r = ClipEditing.split(in: p, clipId: "a", at: 3)!
        XCTAssertEqual(r.project.tracks[0].clips.count, 3)
        XCTAssertEqual(r.project.tracks[0].clips[0].id, "a")
        XCTAssertEqual(r.project.tracks[0].clips[1].id, r.rightId)
        XCTAssertEqual(r.project.tracks[0].clips[2].id, "b")
        XCTAssertNil(ClipEditing.split(in: p, clipId: "a", at: 4))
        XCTAssertNil(ClipEditing.split(in: p, clipId: "nope", at: 3))
    }

    // MARK: delete

    func testDelete() {
        let p = sample()
        let d = ClipEditing.delete(in: p, clipId: "a")!
        XCTAssertEqual(d.allClips.map(\.id), ["b", "c"])
        XCTAssertNil(ClipEditing.delete(in: p, clipId: "zz"))
    }

    // MARK: kindOf / 拡張子

    func testKindOf() {
        for e in ["png", "JPG", "jpeg", "gif", "webp"] { XCTAssertEqual(ClipEditing.kindOf(path: "/x/a.\(e)"), .image, e) }
        for e in ["mp3", "WAV", "m4a", "aac", "ogg"] { XCTAssertEqual(ClipEditing.kindOf(path: "/x/a.\(e)"), .audio, e) }
        for e in ["mp4", "mov", "webm", "m4v", "mkv", "xyz"] { XCTAssertEqual(ClipEditing.kindOf(path: "/x/a.\(e)"), .video, e) }
        XCTAssertEqual(ClipEditing.kindOf(path: "/x/noext"), .video)
        XCTAssertEqual(ClipEditing.kindOf(path: "/x/a.b/c.PNG"), .image)
    }

    func testSupportedMedia() {
        for e in ["mp4", "mov", "webm", "m4v", "png", "jpg", "jpeg", "gif", "webp", "mp3", "wav", "m4a", "aac", "ogg"] {
            XCTAssertTrue(ClipEditing.isSupportedMedia(path: "/a/b.\(e)"), e)
        }
        for e in ["txt", "pdf", "mkv", "ymproj", ""] { XCTAssertFalse(ClipEditing.isSupportedMedia(path: "/a/b.\(e)"), e) }
        XCTAssertEqual(ClipEditing.mediaExtensions.count, 14)
    }

    // MARK: 素材の置き場所

    func testPlacementPicksFirstFreeTrack() {
        var p = sample()                 // T0: a(2〜4) b(8〜10) / T1: c(5〜6) / T2: 空
        XCTAssertEqual(ClipEditing.placementTrack(in: p, start: 0, duration: 1.5), 0)       // [0,1.5) は T0 に重ならない
        XCTAssertEqual(ClipEditing.placementTrack(in: p, start: 0, duration: 5), 1)         // T0 a に重なる。T1 の c は 5 から始まるので接するだけ → T1
        XCTAssertEqual(ClipEditing.placementTrack(in: p, start: 0, duration: 5.5), 2)       // T0 a と T1 c に重なる → T2
        XCTAssertEqual(ClipEditing.placementTrack(in: p, start: 4, duration: 1), 0)         // 接するだけは重ならない(a の終わり 4、b の頭 8)
        XCTAssertEqual(ClipEditing.placementTrack(in: p, start: 6, duration: 2), 0)         // [6,8) は T0 に重ならない
        p.tracks[2].clips = [clip("z", .image, start: 0, dur: 100)]
        XCTAssertEqual(ClipEditing.placementTrack(in: p, start: 3, duration: 5), 0, "どこも空いていなければ 0 番")
    }

    func testPlacementSkipsTracksWithVoice() {
        var p = Project()
        p.tracks = [Track(name: "1"), Track(name: "2")]
        p.tracks[0].clips = [clip("v", .voice, start: 100, dur: 1)]     // 遠くてもボイスがあるレイヤーは避ける
        XCTAssertEqual(ClipEditing.placementTrack(in: p, start: 0, duration: 1), 1)
    }

    func testPlaceMediaOneAfterAnotherOnSuitableTracks() {
        var p = Project()
        let ids = ClipEditing.place(media: [("/a.png", .image, 5), ("/b.mp3", .audio, 3.25), ("/c.mp4", .video, 12)], at: 2, in: &p)
        XCTAssertEqual(ids.count, 3)
        // 順に置く: 2〜7、7〜10.25、10.25〜22.25。どれも空いているので 0 番
        XCTAssertEqual(p.tracks[0].clips.map(\.id), ids)
        XCTAssertEqual(p.tracks[0].clips.map(\.start), [2, 7, 10.25])
        let img = p.tracks[0].clips[0], aud = p.tracks[0].clips[1], vid = p.tracks[0].clips[2]
        XCTAssertEqual(img.type, .image); XCTAssertNil(img.srcDuration); XCTAssertEqual(img.duration, 5)
        XCTAssertEqual(aud.type, .audio); XCTAssertEqual(aud.srcDuration, 3.25); XCTAssertEqual(aud.duration, 3.25)
        XCTAssertEqual(vid.srcDuration, 12)
        for c in [img, aud, vid] {
            XCTAssertEqual(c.offset, 0)
            XCTAssertEqual(c.x, 0.5); XCTAssertEqual(c.y, 0.5); XCTAssertEqual(c.scale, 1); XCTAssertEqual(c.opacity, 1); XCTAssertEqual(c.volume, 1)
        }
        XCTAssertEqual(img.src, "/a.png")
    }

    func testPlaceNeverOverlapsWhenMany() {
        var p = Project()
        let media = (0..<7).map { ("/\($0).png", ClipType.image, 5.0) }
        let ids = ClipEditing.place(media: media, at: 0, in: &p)
        XCTAssertEqual(ids.count, 7)
        XCTAssertEqual(p.tracks[0].clips.count, 7)
        assertNoLayerOverlaps(p)
    }

    func testProbeDurationImageIsFiveAndMissingFileFallsBack() async {
        let d = await ClipEditing.probeDuration(url: URL(fileURLWithPath: "/x.png"), kind: .image)
        XCTAssertEqual(d, 5)
        let m = await ClipEditing.probeDuration(url: URL(fileURLWithPath: "/nonexistent/file.mp3"), kind: .audio)
        XCTAssertEqual(m, 5)
    }

    func testProbeDurationMeasuresRealWav() async throws {
        // 0.5 秒の無音 WAV(16bit mono 8kHz)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ce-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let n = 4000
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + n * 2)); d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1); u32(8000); u32(16000); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(UInt32(n * 2)); d.append(Data(count: n * 2))
        try d.write(to: url)
        let dur = await ClipEditing.probeDuration(url: url, kind: .audio)
        XCTAssertEqual(dur, 0.5, accuracy: 0.01)
    }

    // MARK: テキスト / ぼかし

    private func project(_ w: Int, _ h: Int) -> Project { var p = Project(); p.width = w; p.height = h; return p }

    func testTextClipDefaults() {
        let c = ClipEditing.makeTextClip(at: 1.5, project: project(1920, 1080))
        XCTAssertEqual(c.type, .text); XCTAssertEqual(c.text, "テキスト")
        XCTAssertEqual(c.start, 1.5); XCTAssertEqual(c.duration, 3)
        XCTAssertEqual(c.x, 0.5); XCTAssertEqual(c.y, 0.15)
        XCTAssertEqual(c.fontSize, 96); XCTAssertEqual(c.color, "#ffffff"); XCTAssertEqual(c.outline, "#000000")
        XCTAssertEqual(c.font, defaultFonts[0]); XCTAssertEqual(c.opacity, 1)
    }

    func testTextAndBlurScaleWithResolution() {
        XCTAssertEqual(ClipEditing.makeTextClip(at: 0, project: project(3840, 2160)).fontSize, 192)
        XCTAssertEqual(ClipEditing.makeBlurClip(at: 0, project: project(3840, 2160)).strength, 48)
        // 縦 1080×1920 は面積が同じなので 1
        XCTAssertEqual(ClipEditing.makeTextClip(at: 0, project: project(1080, 1920)).fontSize, 96)
        XCTAssertEqual(ClipEditing.makeBlurClip(at: 0, project: project(1080, 1920)).strength, 24)
        // 縦 720×1280: k = 2/3
        XCTAssertEqual(ClipEditing.makeTextClip(at: 0, project: project(720, 1280)).fontSize, 64)
        XCTAssertEqual(ClipEditing.makeBlurClip(at: 0, project: project(720, 1280)).strength, 16)
        // 極端に小さい解像度でも文字は 8 以上
        XCTAssertEqual(ClipEditing.makeTextClip(at: 0, project: project(100, 100)).fontSize, 8)
        XCTAssertEqual(ClipEditing.resK(project(1920, 1080)), 1, accuracy: 1e-12)
    }

    func testBlurClipDefaults() {
        let c = ClipEditing.makeBlurClip(at: 4, project: project(1920, 1080))
        XCTAssertEqual(c.type, .blur); XCTAssertEqual(c.start, 4); XCTAssertEqual(c.duration, 3)
        XCTAssertEqual(c.x, 0.5); XCTAssertEqual(c.y, 0.5); XCTAssertEqual(c.w, 0.3); XCTAssertEqual(c.h, 0.3)
        XCTAssertEqual(c.strength, 24); XCTAssertEqual(c.shape, "rect")
    }

    func testAppendToTopLayer() {
        var p = sample()
        let c = ClipEditing.makeTextClip(at: 0, project: p)
        ClipEditing.appendToTopLayer(c, in: &p)
        XCTAssertEqual(p.tracks[2].clips.map(\.id), [c.id])
        var empty = Project(); empty.tracks = []
        ClipEditing.appendToTopLayer(c, in: &empty)
        XCTAssertEqual(empty.tracks.count, 1)
    }

    // MARK: スナップショットから作り直す性質

    func testDragIsRecomputedFromSnapshotSoReturningRestoresExactly() {
        let p = sample()
        let there = ClipEditing.move(in: p, clipId: "a", deltaT: 3.3, targetTrackIndex: 2, playhead: 0, pps: 40, snapEnabled: true)
        XCTAssertNotEqual(there.project, p)
        let back = ClipEditing.move(in: p, clipId: "a", deltaT: 0, targetTrackIndex: 0, playhead: 99, pps: 40, snapEnabled: false)
        XCTAssertEqual(back.project, p)
    }
}
