import XCTest
@testable import MovieCutCore

/// クリップ単位の消音: ファイル形式(true のときだけ書く)・音の経路(audibleClips / ダッキング)・編集の断り方。
final class ClipMuteTests: XCTestCase {
    private func clip(_ id: String, _ type: ClipType = .audio, start: Double = 0, dur: Double = 2) -> Clip {
        var c = Clip(); c.id = id; c.type = type; c.start = start; c.duration = dur
        if type == .audio || type == .voice || type == .video { c.src = "/tmp/\(id).wav" }
        return c
    }
    private func sample() -> Project {
        var p = Project.new()
        p.tracks[0].clips = [clip("a"), clip("v", .voice, start: 3)]
        p.tracks[1].clips = [clip("i", .image)]
        return p
    }
    private func compoundProject() -> Project {
        var inner = Track(name: "in"); inner.clips = [clip("k1"), clip("k2", start: 1)]
        var comp = clip("c", .compound, dur: 4); comp.tracks = [inner]
        var p = Project.new()
        p.tracks[0].clips = [comp]
        return p
    }

    // MARK: Codable

    func testCodableRoundTripAndOmission() throws {
        var p = sample()
        XCTAssertFalse(String(decoding: try p.encoded(), as: UTF8.self).contains("\"muted\":true"))
        p.tracks[0].clips[0].muted = false
        XCTAssertFalse(String(decoding: try p.encoded(), as: UTF8.self).contains("\"muted\":true"), "false は書かない")
        p.tracks[0].clips[0].muted = true
        let data = try p.encoded()
        let back = try Project.decode(from: data)
        XCTAssertEqual(back.tracks[0].clips[0].muted, true)
        XCTAssertTrue(back.tracks[0].clips[0].isMuted)
        XCTAssertNil(back.tracks[0].clips[1].muted)
        XCTAssertEqual(try back.encoded(), data)
    }

    func testMissingKeyReadsAsNil() throws {
        let back = try Project.decode(from: try sample().encoded())
        XCTAssertNil(back.tracks[0].clips[0].muted)
        XCTAssertFalse(back.tracks[0].clips[0].isMuted)
    }

    func testNonTrueValueIsPreservedInExtra() throws {
        var c = clip("a")
        c.extra["muted"] = .bool(false)
        var p = Project.new(); p.tracks[0].clips = [c]
        let back = try Project.decode(from: try p.encoded())
        XCTAssertNil(back.tracks[0].clips[0].muted)
        XCTAssertEqual(back.tracks[0].clips[0].extra["muted"], .bool(false))
    }

    // MARK: 音の経路

    func testAudibleClipsExcludesMutedTopLevel() throws {
        let p = try XCTUnwrap(ClipEditing.setMuted(in: sample(), clipId: "a", true))
        XCTAssertEqual(CompoundEditing.audibleClips(in: p).map(\.id), ["v", "i"])
    }

    func testAudibleClipsExcludesMutedCompoundChild() throws {
        let p = try XCTUnwrap(ClipEditing.setMuted(in: compoundProject(), clipId: "k1", true))
        XCTAssertEqual(CompoundEditing.audibleClips(in: p).map(\.id), ["k2"])
    }

    func testMutedClipStaysMutedUnderSolo() throws {
        var p = try XCTUnwrap(ClipEditing.setMuted(in: sample(), clipId: "a", true))
        p.tracks[0].solo = true
        XCTAssertEqual(CompoundEditing.audibleClips(in: p).map(\.id), ["v"])
    }

    func testMutedVoiceDoesNotDuck() throws {
        let p = sample()
        XCTAssertEqual(Ducking.voiceSpans(in: p).count, 1)
        let m = try XCTUnwrap(ClipEditing.setMuted(in: p, clipId: "v", true))
        XCTAssertTrue(Ducking.voiceSpans(in: m).isEmpty, "消音したボイスは BGM を下げる引き金にならない")
    }

    // MARK: 編集

    func testSetMutedToggleAndNoChange() throws {
        let p = sample()
        let m = try XCTUnwrap(ClipEditing.setMuted(in: p, clipId: "a", true))
        XCTAssertEqual(m.tracks[0].clips[0].muted, true)
        XCTAssertNil(ClipEditing.setMuted(in: m, clipId: "a", true), "変わらないときは nil")
        let back = try XCTUnwrap(ClipEditing.setMuted(in: m, clipId: "a", false))
        XCTAssertEqual(try back.encoded(), try p.encoded(), "解除すれば元のファイルと同じ")
        XCTAssertNil(ClipEditing.setMuted(in: p, clipId: "nope", true))
        XCTAssertNil(ClipEditing.setMuted(in: p, clipId: "i", true), "音の無い型(画像)は対象外")
    }

    func testSetMutedWorksInsideCompound() throws {
        let m = try XCTUnwrap(ClipEditing.setMuted(in: compoundProject(), clipId: "k2", true))
        XCTAssertEqual(m.tracks[0].clips[0].tracks?[0].clips[1].muted, true)
        XCTAssertNil(m.tracks[0].clips[0].tracks?[0].clips[0].muted)
        // 複合クリップ自身も消音できる
        let c = try XCTUnwrap(ClipEditing.setMuted(in: compoundProject(), clipId: "c", true))
        XCTAssertTrue(CompoundEditing.audibleClips(in: c).isEmpty)
    }

    func testLockedClipOrLayerRefusesAndKeepsProject() throws {
        var p = sample()
        p.tracks[0].clips[0].locked = true
        XCTAssertNil(ClipEditing.setMuted(in: p, clipId: "a", true))
        var q = sample()
        q.tracks[0].locked = true
        XCTAssertNil(ClipEditing.setMuted(in: q, clipId: "a", true))
        // 複合クリップがロックされていれば、中の子も断る
        var r = compoundProject()
        r.tracks[0].clips[0].locked = true
        XCTAssertNil(ClipEditing.setMuted(in: r, clipId: "k1", true))
        // 一括: ロックされたものは飛ばし、ほかは変わる
        let both = ClipEditing.setClipsMuted(in: p, ids: ["a", "v"], true)
        XCTAssertNil(both?.tracks[0].clips[0].muted)
        XCTAssertEqual(both?.tracks[0].clips[1].muted, true)
    }

    func testAllMutedAndHasMutable() throws {
        let p = sample()
        XCTAssertTrue(ClipEditing.hasMutable(["a"], in: p))
        XCTAssertFalse(ClipEditing.hasMutable(["i"], in: p))
        XCTAssertFalse(ClipEditing.allMuted(["a"], in: p))
        let m = try XCTUnwrap(ClipEditing.setMuted(in: p, clipId: "a", true))
        XCTAssertTrue(ClipEditing.allMuted(["a"], in: m))
        XCTAssertFalse(ClipEditing.allMuted(["a", "v"], in: m))
    }
}
