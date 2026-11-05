import XCTest
@testable import MovieCutCore

/// ロール編集・スリップ編集(Core の純粋な計算)とトラックターゲット。
final class ClipRollSlipTests: XCTestCase {
    private func video(_ id: String, start: Double, dur: Double, offset: Double = 0, src: Double = 10) -> Clip {
        var c = Clip(); c.id = id; c.type = .video; c.src = "/x/\(id).mov"; c.start = start; c.duration = dur
        c.offset = offset; c.srcDuration = src
        return c
    }
    private func image(_ id: String, start: Double, dur: Double) -> Clip {
        var c = Clip(); c.id = id; c.type = .image; c.start = start; c.duration = dur
        return c
    }
    private func get(_ p: Project, _ id: String) -> Clip { p.allClips.first { $0.id == id }! }

    /// a: 0-2 (素材 3-5) / b: 2-5 (素材 1-4)。素材の長さ 10。
    private func pair() -> Project {
        var p = Project.new()
        p.fps = 30
        p.tracks[0].clips = [video("a", start: 0, dur: 2, offset: 3), video("b", start: 2, dur: 3, offset: 1)]
        return p
    }

    // MARK: ロール

    func testRollMovesBoundaryForward() throws {
        let p = try XCTUnwrap(ClipRollSlip.roll(in: pair(), leftClipId: "a", deltaT: 0.5))
        let a = get(p, "a"), b = get(p, "b")
        XCTAssertEqual(a.duration, 2.5, accuracy: 1e-9)
        XCTAssertEqual(a.offset, 3, accuracy: 1e-9)
        XCTAssertEqual(b.start, 2.5, accuracy: 1e-9)
        XCTAssertEqual(b.duration, 2.5, accuracy: 1e-9)
        XCTAssertEqual(b.offset, 1.5, accuracy: 1e-9)
        XCTAssertEqual(a.start + a.duration, b.start, accuracy: 1e-9, "境界はつながったまま")
        XCTAssertEqual(b.start + b.duration, 5, accuracy: 1e-9, "全体の長さは変わらない")
    }

    func testRollMovesBoundaryBackward() throws {
        let p = try XCTUnwrap(ClipRollSlip.roll(in: pair(), leftClipId: "a", deltaT: -0.5))
        let a = get(p, "a"), b = get(p, "b")
        XCTAssertEqual(a.duration, 1.5, accuracy: 1e-9)
        XCTAssertEqual(b.start, 1.5, accuracy: 1e-9)
        XCTAssertEqual(b.duration, 3.5, accuracy: 1e-9)
        XCTAssertEqual(b.offset, 0.5, accuracy: 1e-9)
    }

    func testRollStopsAtSourceLimit() throws {
        // b の素材は頭(offset 1)までしか戻れない: 前へ 5 秒でも 1 秒で止まる
        let p = try XCTUnwrap(ClipRollSlip.roll(in: pair(), leftClipId: "a", deltaT: -5))
        XCTAssertEqual(get(p, "b").offset, 0, accuracy: 1e-9)
        XCTAssertEqual(get(p, "a").duration, 1, accuracy: 1e-9)
        XCTAssertEqual(get(p, "b").start, 1, accuracy: 1e-9)
        // a の素材は 10 秒まで(offset 3 + 長さ 2 → あと 5 秒)。後ろへ 100 秒でも b の長さ(3 秒 - 最短)で止まる
        let q = try XCTUnwrap(ClipRollSlip.roll(in: pair(), leftClipId: "a", deltaT: 100))
        XCTAssertEqual(get(q, "a").duration, 2 + (3 - ClipEditing.minDuration), accuracy: 1e-9)
        XCTAssertEqual(get(q, "b").duration, ClipEditing.minDuration, accuracy: 1e-9)
    }

    func testRollLeftSourceLimit() throws {
        var p = pair()
        p.tracks[0].clips[0].srcDuration = 3.4   // a は素材が 3.4 秒まで(offset 3 + 長さ 2 で既に超過気味)
        p.tracks[0].clips[0].offset = 1.2        // 使っているのは 1.2-3.2 → あと 0.2 秒だけ延ばせる
        let r = try XCTUnwrap(ClipRollSlip.roll(in: p, leftClipId: "a", deltaT: 1))
        XCTAssertEqual(get(r, "a").duration, 2.2, accuracy: 1e-9)
        XCTAssertEqual(get(r, "b").start, 2.2, accuracy: 1e-9)
    }

    func testRollNoOpsReturnNil() {
        XCTAssertNil(ClipRollSlip.roll(in: pair(), leftClipId: "a", deltaT: 0))
        XCTAssertNil(ClipRollSlip.roll(in: pair(), leftClipId: "b", deltaT: 1), "右に隣がない")
        XCTAssertNil(ClipRollSlip.roll(in: pair(), leftClipId: "zzz", deltaT: 1))
        XCTAssertNil(ClipRollSlip.roll(in: pair(), leftClipId: "a", deltaT: .nan))
        var gap = pair()
        gap.tracks[0].clips[1].start = 2.5
        XCTAssertNil(ClipRollSlip.roll(in: gap, leftClipId: "a", deltaT: 0.5), "隙間があれば隣り合わない")
        // 素材の頭で既に止まっている側へはこれ以上動かない
        var atHead = pair()
        atHead.tracks[0].clips[1].offset = 0
        XCTAssertNil(ClipRollSlip.roll(in: atHead, leftClipId: "a", deltaT: -1))
    }

    func testRollRefusesLocked() {
        var p = pair()
        p.tracks[0].clips[1].locked = true
        XCTAssertNil(ClipRollSlip.roll(in: p, leftClipId: "a", deltaT: 0.5))
        XCTAssertNotNil(ClipRollSlip.rollBlockedReason(in: p, clipId: "a"))
        var q = pair()
        q.tracks[0].locked = true
        XCTAssertNil(ClipRollSlip.roll(in: q, leftClipId: "a", deltaT: 0.5))
        var r = pair()
        r.tracks[0].clips[0].locked = true
        XCTAssertNil(ClipRollSlip.roll(in: r, leftClipId: "a", deltaT: -0.5))
    }

    func testRollImagesAndFrames() throws {
        var p = Project.new()
        p.fps = 30
        p.tracks[0].clips = [image("i", start: 0, dur: 2), image("j", start: 2, dur: 2)]
        let r = try XCTUnwrap(ClipRollSlip.roll(in: p, leftClipId: "i", frames: 3))
        XCTAssertEqual(get(r, "i").duration, 2.1, accuracy: 1e-9)
        XCTAssertEqual(get(r, "j").start, 2.1, accuracy: 1e-9)
        XCTAssertEqual(get(r, "j").offset, 0, "画像の offset は動かさない")
        XCTAssertNil(ClipRollSlip.roll(in: p, leftClipId: "i", frames: 0))
    }

    func testRollReverseAndSpeed() throws {
        var p = pair()
        p.tracks[0].clips[1].speed = 2    // b は 2 倍速: 頭を 0.5 秒縮めると素材は 1 秒進む
        let r = try XCTUnwrap(ClipRollSlip.roll(in: p, leftClipId: "a", deltaT: 0.5))
        XCTAssertEqual(get(r, "b").offset, 2, accuracy: 1e-9)
        XCTAssertEqual(get(r, "b").duration, 2.5, accuracy: 1e-9)
    }

    func testBoundaryLookup() {
        let p = pair()
        XCTAssertEqual(ClipRollSlip.boundary(for: "a", in: p)?.right, "b")
        XCTAssertEqual(ClipRollSlip.boundary(for: "b", in: p)?.left, "a")
        var lone = Project.new()
        lone.tracks[0].clips = [image("x", start: 0, dur: 1)]
        XCTAssertNil(ClipRollSlip.boundary(for: "x", in: lone))
    }

    // MARK: スリップ

    func testSlipShiftsOffsetKeepsPosition() throws {
        let p = try XCTUnwrap(ClipRollSlip.slip(in: pair(), clipId: "b", deltaT: 1))
        let b = get(p, "b")
        XCTAssertEqual(b.offset, 2, accuracy: 1e-9)
        XCTAssertEqual(b.start, 2); XCTAssertEqual(b.duration, 3)
        let q = try XCTUnwrap(ClipRollSlip.slip(in: pair(), clipId: "b", deltaT: -0.5))
        XCTAssertEqual(get(q, "b").offset, 0.5, accuracy: 1e-9)
    }

    func testSlipLimits() throws {
        // 前: 素材の頭(0)で止まる
        let a = try XCTUnwrap(ClipRollSlip.slip(in: pair(), clipId: "b", deltaT: -50))
        XCTAssertEqual(get(a, "b").offset, 0, accuracy: 1e-9)
        // 後ろ: offset + 長さ ≦ 素材の長さ(10 - 3 = 7)
        let b = try XCTUnwrap(ClipRollSlip.slip(in: pair(), clipId: "b", deltaT: 50))
        XCTAssertEqual(get(b, "b").offset, 7, accuracy: 1e-9)
        // 端にいるときはそれ以上動かない = nil
        XCTAssertNil(ClipRollSlip.slip(in: a, clipId: "b", deltaT: -1))
        XCTAssertNil(ClipRollSlip.slip(in: b, clipId: "b", deltaT: 1))
        // 速度: 2 倍速なら長さ 3 秒で素材 6 秒を使う。タイムライン 1 秒のスリップ = 素材 2 秒
        var p = pair()
        p.tracks[0].clips[1].speed = 2
        let c = try XCTUnwrap(ClipRollSlip.slip(in: p, clipId: "b", deltaT: 1))
        XCTAssertEqual(get(c, "b").offset, 3, accuracy: 1e-9)
        let d = try XCTUnwrap(ClipRollSlip.slip(in: p, clipId: "b", deltaT: 50))
        XCTAssertEqual(get(d, "b").offset, 4, accuracy: 1e-9, "10 - 6")
    }

    func testSlipRefusals() {
        XCTAssertNil(ClipRollSlip.slip(in: pair(), clipId: "a", deltaT: 0))
        XCTAssertNil(ClipRollSlip.slip(in: pair(), clipId: "zzz", deltaT: 1))
        var p = pair()
        p.tracks[0].clips = [image("i", start: 0, dur: 2)]
        XCTAssertNil(ClipRollSlip.slip(in: p, clipId: "i", deltaT: 1), "画像はスリップできない")
        var q = pair()
        q.tracks[0].clips[0].locked = true
        XCTAssertNil(ClipRollSlip.slip(in: q, clipId: "a", deltaT: 1))
        XCTAssertNotNil(ClipRollSlip.slipBlockedReason(in: q, clipId: "a"))
        var f = pair()
        f.tracks[0].clips[0].freeze = true
        XCTAssertNil(ClipRollSlip.slip(in: f, clipId: "a", deltaT: 1), "フリーズは対象外")
        var l = pair()
        l.tracks[0].locked = true
        XCTAssertNil(ClipRollSlip.slip(in: l, clipId: "b", deltaT: 1))
    }

    func testSlipFramesAndKeyframesUntouched() throws {
        var p = pair()
        p.tracks[0].clips[1].opacity = 0.5
        let r = try XCTUnwrap(ClipRollSlip.slip(in: p, clipId: "b", frames: 30))
        XCTAssertEqual(get(r, "b").offset, 2, accuracy: 1e-9)
        var expected = get(r, "b"); expected.offset = 1
        XCTAssertEqual(expected, get(p, "b"), "offset 以外は変わらない")
    }

    // MARK: トラックターゲット

    func testTargetSetToggleAndFileFormat() throws {
        let base = Project.new()
        XCTAssertFalse(String(decoding: try base.encoded(), as: UTF8.self).contains("targetTrackId"), "既定では書かない")
        let p = try XCTUnwrap(TrackTarget.set(in: base, index: 2, on: true))
        XCTAssertEqual(TrackTarget.index(in: p), 2)
        XCTAssertNil(TrackTarget.set(in: p, index: 2, on: true), "同じ状態は nil")
        let moved = try XCTUnwrap(TrackTarget.toggle(in: p, index: 0))
        XCTAssertEqual(TrackTarget.index(in: moved), 0, "1 つだけ")
        let back = try Project.decode(from: try p.encoded())
        XCTAssertEqual(TrackTarget.index(in: back), 2)
        XCTAssertEqual(try back.encoded(), try p.encoded())
        let off = try XCTUnwrap(TrackTarget.toggle(in: p, index: 2))
        XCTAssertEqual(try off.encoded(), try base.encoded(), "外せば元のファイルと同じ")
        XCTAssertNil(TrackTarget.set(in: base, index: 0, on: false))
        XCTAssertNil(TrackTarget.set(in: base, index: 99, on: true))
    }

    func testOldFixturesUnchangedByTargetField() throws {
        for name in ["rich", "timeline", "transitions", "effects", "keyframes"] {
            let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "ymproj", subdirectory: "Fixtures"))
            let data = try Data(contentsOf: url)
            let p = try Project.decode(from: data)
            XCTAssertNil(p.targetTrackId)
            XCTAssertFalse(String(decoding: try p.encoded(), as: UTF8.self).contains("targetTrackId"), name)
            XCTAssertEqual(try Project.decode(from: try p.encoded()).encoded(), try p.encoded(), name)
        }
    }

    func testWrongTypedTargetFieldIsPreserved() throws {
        let json = #"{"width":1920,"height":1080,"fps":60,"tracks":[],"targetTrackId":5}"#
        let p = try Project.decode(from: Data(json.utf8))
        XCTAssertNil(p.targetTrackId)
        let again = try Project.decode(from: try p.encoded())
        XCTAssertNotNil(again.extra["targetTrackId"], "読めなかった値は捨てずに書き戻す")
        XCTAssertEqual(try again.encoded(), try p.encoded())
    }

    func testDeletingTargetLayerClearsTarget() throws {
        var p = try XCTUnwrap(TrackTarget.set(in: Project.new(), index: 1, on: true))
        p = try XCTUnwrap(LayerEditing.delete(in: p, index: 1))
        XCTAssertNil(p.targetTrackId)
        XCTAssertNil(TrackTarget.index(in: p))
        var dangling = Project.new(); dangling.targetTrackId = "missing"
        XCTAssertNil(TrackTarget.index(in: dangling))
    }

    func testMediaPlacementUsesTargetUnlessLockedOrOccupied() throws {
        let media = [(path: "/x/m.mov", kind: ClipType.video, duration: 2.0)]
        var p = try XCTUnwrap(TrackTarget.set(in: Project.new(), index: 3, on: true))
        let ids = ClipEditing.place(media: media, at: 1, preferredTrack: TrackTarget.index(in: p), in: &p)
        XCTAssertEqual(ClipEditing.locate(ids[0], in: p)?.track, 3)
        // 埋まっていれば今までどおり(別のレイヤー。重ならない)
        let ids2 = ClipEditing.place(media: media, at: 1.5, preferredTrack: TrackTarget.index(in: p), in: &p)
        XCTAssertNotEqual(ClipEditing.locate(ids2[0], in: p)?.track, 3)
        // ロックされたレイヤーには置かない
        var q = try XCTUnwrap(TrackTarget.set(in: Project.new(), index: 3, on: true))
        q.tracks[3].locked = true
        let ids3 = ClipEditing.place(media: media, at: 0, preferredTrack: TrackTarget.index(in: q), in: &q)
        XCTAssertNotEqual(ClipEditing.locate(ids3[0], in: q)?.track, 3)
    }

    func testTextAndSubtitleUseTarget() throws {
        var p = try XCTUnwrap(TrackTarget.set(in: Project.new(), index: 1, on: true))
        let t = ClipEditing.makeTextClip(at: 0, project: p)
        ClipEditing.appendToTopLayer(t, in: &p, useTarget: true)
        XCTAssertEqual(ClipEditing.locate(t.id, in: p)?.track, 1)
        // useTarget なし(既定)は今までどおり一番上
        let u = ClipEditing.makeTextClip(at: 10, project: p)
        ClipEditing.appendToTopLayer(u, in: &p)
        XCTAssertEqual(ClipEditing.locate(u.id, in: p)?.track, p.tracks.count - 1)
        // 字幕
        let s = try XCTUnwrap(SubtitleQuickAdd.add(text: "こんにちは", at: 20, to: p))
        XCTAssertEqual(s.trackIndex, 1)
        XCTAssertEqual(p.tracks.count, s.project.tracks.count, "新しいレイヤーは作らない")
        // ターゲットが無ければ今までどおり字幕レイヤーを作る
        let n = try XCTUnwrap(SubtitleQuickAdd.add(text: "こんにちは", at: 20, to: Project.new()))
        XCTAssertEqual(n.project.tracks[n.trackIndex].name, SubtitleFile.layerName)
        // ロックされたターゲットは使わない
        var l = p; l.tracks[1].locked = true
        let s2 = try XCTUnwrap(SubtitleQuickAdd.add(text: "x", at: 30, to: l))
        XCTAssertNotEqual(s2.trackIndex, 1)
    }
}
