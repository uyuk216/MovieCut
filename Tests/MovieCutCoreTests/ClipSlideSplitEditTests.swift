import XCTest
@testable import MovieCutCore

/// スライド編集(ClipRollSlip.slide)と J/Lカット(ClipSplitEdit)。
final class ClipSlideSplitEditTests: XCTestCase {
    private func video(_ id: String, start: Double, dur: Double, offset: Double = 0, src: Double = 10) -> Clip {
        var c = Clip(); c.id = id; c.type = .video; c.src = "/x/\(id).mov"; c.start = start; c.duration = dur
        c.offset = offset; c.srcDuration = src
        return c
    }
    private func sound(_ id: String, start: Double, dur: Double, offset: Double = 0, src: Double = 20, type: ClipType = .audio) -> Clip {
        var c = Clip(); c.id = id; c.type = type; c.src = "/x/\(id).wav"; c.start = start; c.duration = dur
        c.offset = offset; c.srcDuration = src
        return c
    }
    private func image(_ id: String, start: Double, dur: Double) -> Clip {
        var c = Clip(); c.id = id; c.type = .image; c.start = start; c.duration = dur
        return c
    }
    private func get(_ p: Project, _ id: String) -> Clip { p.allClips.first { $0.id == id }! }

    /// a: 0-2 (素材 3-5) / b: 2-5 (素材 1-4) / c: 5-7 (素材 2-4)。素材の長さ 10。
    private func triple() -> Project {
        var p = Project.new()
        p.fps = 30
        p.tracks[0].clips = [video("a", start: 0, dur: 2, offset: 3), video("b", start: 2, dur: 3, offset: 1), video("c", start: 5, dur: 2, offset: 2)]
        return p
    }

    // MARK: スライド

    func testSlideForward() throws {
        let p = try XCTUnwrap(ClipRollSlip.slide(in: triple(), clipId: "b", deltaT: 0.5))
        let a = get(p, "a"), b = get(p, "b"), c = get(p, "c")
        XCTAssertEqual(a.duration, 2.5, accuracy: 1e-9)
        XCTAssertEqual(b.start, 2.5, accuracy: 1e-9)
        XCTAssertEqual(b.duration, 3, accuracy: 1e-9, "真ん中の長さは変わらない")
        XCTAssertEqual(b.offset, 1, accuracy: 1e-9, "真ん中の素材の区間は変わらない")
        XCTAssertEqual(c.start, 5.5, accuracy: 1e-9)
        XCTAssertEqual(c.duration, 1.5, accuracy: 1e-9)
        XCTAssertEqual(c.offset, 2.5, accuracy: 1e-9)
        XCTAssertEqual(c.start + c.duration, 7, accuracy: 1e-9, "全体の長さは変わらない")
    }

    func testSlideBackward() throws {
        let p = try XCTUnwrap(ClipRollSlip.slide(in: triple(), clipId: "b", deltaT: -0.5))
        let a = get(p, "a"), b = get(p, "b"), c = get(p, "c")
        XCTAssertEqual(a.duration, 1.5, accuracy: 1e-9)
        XCTAssertEqual(b.start, 1.5, accuracy: 1e-9)
        XCTAssertEqual(b.offset, 1, accuracy: 1e-9)
        XCTAssertEqual(c.start, 4.5, accuracy: 1e-9)
        XCTAssertEqual(c.duration, 2.5, accuracy: 1e-9)
        XCTAssertEqual(c.offset, 1.5, accuracy: 1e-9)
    }

    func testSlideStopsAtRightClipMinDuration() throws {
        // 後ろへ大きく: c の長さ(2 - 最短 0.05)までで止まる
        let p = try XCTUnwrap(ClipRollSlip.slide(in: triple(), clipId: "b", deltaT: 100))
        XCTAssertEqual(get(p, "b").start, 2 + (2 - ClipEditing.minDuration), accuracy: 1e-9)
        XCTAssertEqual(get(p, "c").duration, ClipEditing.minDuration, accuracy: 1e-9)
        XCTAssertEqual(get(p, "a").duration, 2 + (2 - ClipEditing.minDuration), accuracy: 1e-9)
    }

    func testSlideStopsAtLeftClipMinDuration() throws {
        // 前へ大きく: a の長さ(2 - 最短)までで止まる(c の素材の頭までは 2 秒ある)
        let p = try XCTUnwrap(ClipRollSlip.slide(in: triple(), clipId: "b", deltaT: -100))
        XCTAssertEqual(get(p, "a").duration, ClipEditing.minDuration, accuracy: 1e-9)
        XCTAssertEqual(get(p, "b").start, ClipEditing.minDuration, accuracy: 1e-9)
        XCTAssertEqual(get(p, "c").start, 5 - (2 - ClipEditing.minDuration), accuracy: 1e-9)
    }

    func testSlideStopsAtRightSourceHead() throws {
        var t = triple()
        t.tracks[0].clips[2].offset = 0.3   // c は素材の頭まで 0.3 秒しか戻れない
        let p = try XCTUnwrap(ClipRollSlip.slide(in: t, clipId: "b", deltaT: -1))
        XCTAssertEqual(get(p, "b").start, 1.7, accuracy: 1e-9)
        XCTAssertEqual(get(p, "c").offset, 0, accuracy: 1e-9)
    }

    func testSlideNoOpsReturnNil() {
        XCTAssertNil(ClipRollSlip.slide(in: triple(), clipId: "b", deltaT: 0))
        XCTAssertNil(ClipRollSlip.slide(in: triple(), clipId: "b", deltaT: .nan))
        XCTAssertNil(ClipRollSlip.slide(in: triple(), clipId: "a", deltaT: 0.5), "前に隣がない")
        XCTAssertNil(ClipRollSlip.slide(in: triple(), clipId: "c", deltaT: 0.5), "後ろに隣がない")
        XCTAssertNil(ClipRollSlip.slide(in: triple(), clipId: "zzz", deltaT: 0.5))
        var gap = triple()
        gap.tracks[0].clips[2].start = 5.5
        XCTAssertNil(ClipRollSlip.slide(in: gap, clipId: "b", deltaT: 0.5), "隙間があれば挟まれていない")
        XCTAssertNotNil(ClipRollSlip.slideBlockedReason(in: gap, clipId: "b"))
        XCTAssertNil(ClipRollSlip.slideBlockedReason(in: triple(), clipId: "b"))
    }

    func testSlideRefusesLocked() {
        for i in 0...2 {
            var p = triple()
            p.tracks[0].clips[i].locked = true
            XCTAssertNil(ClipRollSlip.slide(in: p, clipId: "b", deltaT: 0.5), "ロック \(i)")
        }
        var q = triple()
        q.tracks[0].locked = true
        XCTAssertNil(ClipRollSlip.slide(in: q, clipId: "b", deltaT: 0.5))
    }

    func testSlideImagesAndFrames() throws {
        var p = Project.new()
        p.fps = 30
        p.tracks[0].clips = [image("i", start: 0, dur: 2), image("j", start: 2, dur: 2), image("k", start: 4, dur: 2)]
        let r = try XCTUnwrap(ClipRollSlip.slide(in: p, clipId: "j", frames: 30))
        XCTAssertEqual(get(r, "i").duration, 3, accuracy: 1e-9)
        XCTAssertEqual(get(r, "j").start, 3, accuracy: 1e-9)
        XCTAssertEqual(get(r, "k").start, 5, accuracy: 1e-9)
        XCTAssertEqual(get(r, "k").duration, 1, accuracy: 1e-9)
        XCTAssertNil(ClipRollSlip.slide(in: p, clipId: "j", frames: 0))
    }

    // MARK: J/Lカット

    /// 映像: v1 0-4 / v2 4-8(レイヤー 0)。音: s1 0-4 / s2 4-8(レイヤー 1)。境界は 4 秒でそろっている。
    private func avPair() -> Project {
        var p = Project.new()
        p.fps = 30
        p.tracks[0].clips = [video("v1", start: 0, dur: 4, offset: 0, src: 20), video("v2", start: 4, dur: 4, offset: 4, src: 20)]
        p.tracks[1].clips = [sound("s1", start: 0, dur: 4, offset: 0), sound("s2", start: 4, dur: 4, offset: 4)]
        return p
    }

    func testLCutMovesOnlySoundBoundaryLater() throws {
        let p = try XCTUnwrap(ClipSplitEdit.splitEdit(in: avPair(), anchorClipId: "v1", deltaT: 0.5))
        XCTAssertEqual(get(p, "s1").duration, 4.5, accuracy: 1e-9, "前の音が残る")
        XCTAssertEqual(get(p, "s2").start, 4.5, accuracy: 1e-9)
        XCTAssertEqual(get(p, "s2").offset, 4.5, accuracy: 1e-9)
        XCTAssertEqual(get(p, "v1").duration, 4, accuracy: 1e-9, "映像の境界は動かない")
        XCTAssertEqual(get(p, "v2").start, 4, accuracy: 1e-9)
        XCTAssertEqual(ClipSplitEdit.kind(forDelta: 0.5), "Lカット")
    }

    func testJCutMovesOnlySoundBoundaryEarlier() throws {
        // アンカーは音の右側(s2)でも、映像側(v2)でもよい
        for anchor in ["s2", "v2", "s1"] {
            let p = try XCTUnwrap(ClipSplitEdit.splitEdit(in: avPair(), anchorClipId: anchor, deltaT: -0.5), "anchor \(anchor)")
            XCTAssertEqual(get(p, "s1").duration, 3.5, accuracy: 1e-9, "次の音が先に出る")
            XCTAssertEqual(get(p, "s2").start, 3.5, accuracy: 1e-9)
            XCTAssertEqual(get(p, "s2").offset, 3.5, accuracy: 1e-9)
            XCTAssertEqual(get(p, "v1").duration, 4, accuracy: 1e-9)
            XCTAssertEqual(get(p, "v2").start, 4, accuracy: 1e-9)
        }
        XCTAssertEqual(ClipSplitEdit.kind(forDelta: -0.5), "Jカット")
        XCTAssertNil(ClipSplitEdit.kind(forDelta: 0))
    }

    func testSplitEditStopsAtSourceHead() throws {
        // J 方向へ大きく: s1 の最短の長さで止まる(s2 の素材の頭までは 4 秒)
        let p = try XCTUnwrap(ClipSplitEdit.splitEdit(in: avPair(), anchorClipId: "s1", deltaT: -10))
        XCTAssertEqual(get(p, "s1").duration, ClipEditing.minDuration, accuracy: 1e-9)
        XCTAssertEqual(get(p, "s2").start, ClipEditing.minDuration, accuracy: 1e-9)
        XCTAssertEqual(get(p, "s2").offset, 4 - (4 - ClipEditing.minDuration), accuracy: 1e-9)
        XCTAssertEqual(get(p, "v2").start, 4, accuracy: 1e-9, "映像は変わらない")
    }

    func testSplitEditVoiceClipsCountAsSound() throws {
        var p = avPair()
        p.tracks[1].clips = [sound("s1", start: 0, dur: 4, offset: 0, type: .voice), sound("s2", start: 4, dur: 4, offset: 4, type: .voice)]
        let r = try XCTUnwrap(ClipSplitEdit.splitEdit(in: p, anchorClipId: "v1", frames: 15))
        XCTAssertEqual(get(r, "s1").duration, 4.5, accuracy: 1e-9)
    }

    func testSplitEditNoOpsReturnNil() {
        XCTAssertNil(ClipSplitEdit.splitEdit(in: avPair(), anchorClipId: "v1", deltaT: 0))
        XCTAssertNil(ClipSplitEdit.splitEdit(in: avPair(), anchorClipId: "zzz", deltaT: 0.5))
        // 映像の境界が無い(映像が 1 本だけ)
        var noPic = avPair()
        noPic.tracks[0].clips = [video("v1", start: 0, dur: 8, offset: 0, src: 20)]
        XCTAssertNil(ClipSplitEdit.splitEdit(in: noPic, anchorClipId: "s1", deltaT: 0.5))
        XCTAssertNotNil(ClipSplitEdit.splitEditBlockedReason(in: noPic, anchorClipId: "s1"))
        // 音の境界が無い(音が 1 本だけ)
        var noSound = avPair()
        noSound.tracks[1].clips = [sound("s1", start: 0, dur: 8, offset: 0)]
        XCTAssertNil(ClipSplitEdit.splitEdit(in: noSound, anchorClipId: "v1", deltaT: 0.5))
        // ロックされた音は断る
        var locked = avPair()
        locked.tracks[1].clips[0].locked = true
        XCTAssertNil(ClipSplitEdit.splitEdit(in: locked, anchorClipId: "v1", deltaT: 0.5))
        XCTAssertNil(ClipSplitEdit.splitEditBlockedReason(in: avPair(), anchorClipId: "v1"))
    }
}


/// J/Lカットは、選択した音声レイヤーの組を動かすこと(第2部 C11)。
final class ClipSplitEditAnchorLayerTests: XCTestCase {
    private func clip(_ id: String, _ type: ClipType, start: Double, dur: Double) -> Clip {
        var c = Clip(); c.id = id; c.type = type; c.start = start; c.duration = dur; c.src = "/x.wav"; return c
    }

    func testSplitEditMovesAnchorsOwnSoundPair() {
        // 映像 1 本 + 音声 2 本、どれにも 5 秒の境界がある。
        // 後ろの音声レイヤーをアンカーにしたら、そのレイヤーの組だけが動く。
        var p = Project.new()
        var v = Track(name: "V"); v.clips = [clip("v1", .video, start: 0, dur: 5), clip("v2", .video, start: 5, dur: 5)]
        var a = Track(name: "A1"); a.clips = [clip("a1", .audio, start: 0, dur: 5), clip("a2", .audio, start: 5, dur: 5)]
        var b = Track(name: "A2"); b.clips = [clip("b1", .audio, start: 0, dur: 5), clip("b2", .audio, start: 5, dur: 5)]
        p.tracks = [v, a, b]
        let r = ClipSplitEdit.splitEdit(in: p, anchorClipId: "b1", deltaT: 1)
        XCTAssertNotNil(r)
        XCTAssertEqual(r?.allClips.first { $0.id == "b1" }?.duration, 6)
        XCTAssertEqual(r?.allClips.first { $0.id == "b2" }?.start, 6)
        XCTAssertEqual(r?.allClips.first { $0.id == "a1" }?.duration, 5, "選択していない音声レイヤーは動かない")
        XCTAssertEqual(r?.allClips.first { $0.id == "a2" }?.start, 5)
    }
}
