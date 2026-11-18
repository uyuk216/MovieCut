import XCTest
@testable import MovieCutCore

/// 「声として扱う」指定: ファイル形式・声の区間(ダッキング)・編集の断り方。
final class ClipVoiceTests: XCTestCase {
    private func clip(_ id: String, _ type: ClipType = .audio, start: Double = 0, dur: Double = 2) -> Clip {
        var c = Clip(); c.id = id; c.type = type; c.start = start; c.duration = dur
        if type == .audio || type == .voice || type == .video { c.src = "/tmp/\(id).wav" }
        return c
    }
    private func sample() -> Project {
        var p = Project.new()
        p.tracks[0].clips = [clip("a"), clip("v", .voice, start: 3)]
        p.tracks[1].clips = [clip("i", .image), clip("m", .video, start: 6)]
        return p
    }
    private func compoundProject() -> Project {
        var inner = Track(name: "in"); inner.clips = [clip("k1"), clip("k2", start: 1)]
        var comp = clip("c", .compound, dur: 4); comp.tracks = [inner]
        var p = Project.new()
        p.tracks[0].clips = [comp]
        return p
    }
    private func designated(_ p: Project, _ id: String) throws -> Project {
        try XCTUnwrap(ClipEditing.setTreatedAsVoice(in: p, clipId: id, true))
    }

    // MARK: Codable

    func testCodableRoundTripAndOmission() throws {
        var p = sample()
        XCTAssertFalse(String(decoding: try p.encoded(), as: UTF8.self).contains("treatAsVoice"))
        p.tracks[0].clips[0].treatAsVoice = false
        XCTAssertFalse(String(decoding: try p.encoded(), as: UTF8.self).contains("treatAsVoice"), "false は書かない")
        p.tracks[0].clips[0].treatAsVoice = true
        let data = try p.encoded()
        XCTAssertTrue(String(decoding: data, as: UTF8.self).range(of: #"\"treatAsVoice\"\s*:\s*true"#, options: .regularExpression) != nil)
        let back = try Project.decode(from: data)
        XCTAssertEqual(back.tracks[0].clips[0].treatAsVoice, true)
        XCTAssertTrue(back.tracks[0].clips[0].isTreatedAsVoice)
        XCTAssertNil(back.tracks[0].clips[1].treatAsVoice)
        XCTAssertEqual(try back.encoded(), data)
    }

    func testMissingKeyReadsAsNil() throws {
        let back = try Project.decode(from: try sample().encoded())
        XCTAssertNil(back.tracks[0].clips[0].treatAsVoice)
        XCTAssertFalse(back.tracks[0].clips[0].isTreatedAsVoice)
    }

    func testNonTrueValuesArePreservedInExtra() throws {
        for raw in [JSONValue.bool(false), .string("yes")] {
            var c = clip("a")
            c.extra["treatAsVoice"] = raw
            var p = Project.new(); p.tracks[0].clips = [c]
            let data = try p.encoded()
            let back = try Project.decode(from: data)
            XCTAssertNil(back.tracks[0].clips[0].treatAsVoice)
            XCTAssertEqual(back.tracks[0].clips[0].extra["treatAsVoice"], raw)
            XCTAssertEqual(try back.encoded(), data, "書き戻せる")
        }
    }

    // MARK: 声の区間

    func testDesignatedAudioBecomesVoiceSpan() throws {
        let p = sample()
        XCTAssertEqual(Ducking.voiceSpans(in: p), [Ducking.Span(start: 3, end: 5)], "指定なしの音声は入らない")
        let d = try designated(p, "a")
        XCTAssertEqual(Ducking.voiceSpans(in: d), [Ducking.Span(start: 0, end: 2), Ducking.Span(start: 3, end: 5)])
    }

    func testDesignatedAudioIsIgnoredWhenSilent() throws {
        let d = try designated(sample(), "a")
        let muted = try XCTUnwrap(ClipEditing.setMuted(in: d, clipId: "a", true))
        XCTAssertEqual(Ducking.voiceSpans(in: muted), [Ducking.Span(start: 3, end: 5)])
        var zero = d; zero.tracks[0].clips[0].volume = 0
        XCTAssertEqual(Ducking.voiceSpans(in: zero), [Ducking.Span(start: 3, end: 5)])
        var nosrc = d; nosrc.tracks[0].clips[0].src = nil
        XCTAssertEqual(Ducking.voiceSpans(in: nosrc), [Ducking.Span(start: 3, end: 5)])
        var empty = d; empty.tracks[0].clips[0].src = ""
        XCTAssertEqual(Ducking.voiceSpans(in: empty), [Ducking.Span(start: 3, end: 5)])
    }

    func testDesignatedAudioInsideCompoundCounts() throws {
        let d = try designated(compoundProject(), "k2")
        XCTAssertEqual(Ducking.voiceSpans(in: d).count, 1)
        XCTAssertTrue(Ducking.voiceSpans(in: compoundProject()).isEmpty)
    }

    func testOverlappingSpansMerge() throws {
        var p = sample()
        p.tracks[0].clips.append(clip("b", start: 1))   // 1〜3
        p = try designated(p, "a")
        p = try designated(p, "b")
        XCTAssertEqual(Ducking.voiceSpans(in: p), [Ducking.Span(start: 0, end: 5)], "0〜2・1〜3・3〜5 が 1 つになる")
    }

    func testIsVoiceSource() {
        var a = clip("a"); XCTAssertFalse(a.isVoiceSource)
        a.treatAsVoice = true; XCTAssertTrue(a.isVoiceSource)
        XCTAssertTrue(clip("v", .voice).isVoiceSource)
        var m = clip("m", .video); m.treatAsVoice = true
        XCTAssertFalse(m.isVoiceSource, "動画は指定の対象外")
    }

    // MARK: 編集操作

    func testSetToggleAndNoChange() throws {
        let p = sample()
        let d = try designated(p, "a")
        XCTAssertEqual(d.tracks[0].clips[0].treatAsVoice, true)
        XCTAssertNil(ClipEditing.setTreatedAsVoice(in: d, clipId: "a", true), "変わらないときは nil")
        let back = try XCTUnwrap(ClipEditing.setTreatedAsVoice(in: d, clipId: "a", false))
        XCTAssertEqual(try back.encoded(), try p.encoded(), "解除すれば元のファイルと同じ")
        XCTAssertNil(ClipEditing.setTreatedAsVoice(in: p, clipId: "a", false))
        XCTAssertNil(ClipEditing.setTreatedAsVoice(in: p, clipId: "nope", true))
    }

    func testSettingClearsExtraAndClearingResetsField() throws {
        var p = sample()
        p.tracks[0].clips[0].extra["treatAsVoice"] = .bool(false)
        let d = try designated(p, "a")
        XCTAssertNil(d.tracks[0].clips[0].extra["treatAsVoice"])
        XCTAssertEqual(d.tracks[0].clips[0].treatAsVoice, true)
        let off = try XCTUnwrap(ClipEditing.setTreatedAsVoice(in: d, clipId: "a", false))
        XCTAssertNil(off.tracks[0].clips[0].treatAsVoice)
    }

    func testBatchSetAndUnsupportedTypes() throws {
        var p = sample()
        p.tracks[0].clips.append(clip("b", start: 8))
        let d = try XCTUnwrap(ClipEditing.setClipsTreatedAsVoice(in: p, ids: ["a", "b", "v", "i", "m"], true))
        XCTAssertEqual(d.tracks[0].clips[0].treatAsVoice, true)
        XCTAssertEqual(d.tracks[0].clips[2].treatAsVoice, true)
        XCTAssertNil(d.tracks[0].clips[1].treatAsVoice, "ボイスクリップは対象外")
        XCTAssertNil(d.tracks[1].clips[0].treatAsVoice, "画像は対象外")
        XCTAssertNil(d.tracks[1].clips[1].treatAsVoice, "動画は対象外")
        XCTAssertNil(ClipEditing.setClipsTreatedAsVoice(in: p, ids: ["v", "i", "m"], true))
        XCTAssertTrue(ClipEditing.supportsVoiceDesignation(clip("a")))
        XCTAssertFalse(ClipEditing.supportsVoiceDesignation(clip("v", .voice)))
        XCTAssertFalse(ClipEditing.supportsVoiceDesignation(clip("m", .video)))
    }

    func testWorksInsideCompound() throws {
        let d = try designated(compoundProject(), "k2")
        XCTAssertEqual(d.tracks[0].clips[0].tracks?[0].clips[1].treatAsVoice, true)
        XCTAssertNil(d.tracks[0].clips[0].tracks?[0].clips[0].treatAsVoice)
        XCTAssertNil(ClipEditing.setTreatedAsVoice(in: compoundProject(), clipId: "c", true), "複合クリップ自身は対象外")
    }

    func testLockedClipOrLayerRefusesAndKeepsProject() throws {
        var p = sample()
        p.tracks[0].clips[0].locked = true
        XCTAssertNil(ClipEditing.setTreatedAsVoice(in: p, clipId: "a", true))
        var q = sample()
        q.tracks[0].locked = true
        XCTAssertNil(ClipEditing.setTreatedAsVoice(in: q, clipId: "a", true))
        var r = compoundProject()
        r.tracks[0].clips[0].locked = true
        XCTAssertNil(ClipEditing.setTreatedAsVoice(in: r, clipId: "k1", true))
        var s = compoundProject()
        s.tracks[0].locked = true
        XCTAssertNil(ClipEditing.setTreatedAsVoice(in: s, clipId: "k1", true))
        // 一括: ロックされたものは飛ばし、ほかは変わる
        var t = sample()
        t.tracks[0].clips[0].locked = true
        t.tracks[1].clips.append(clip("b", start: 9))
        let both = ClipEditing.setClipsTreatedAsVoice(in: t, ids: ["a", "b"], true)
        XCTAssertNil(both?.tracks[0].clips[0].treatAsVoice)
        XCTAssertEqual(both?.tracks[1].clips[2].treatAsVoice, true)
    }

    func testAllTreatedAsVoiceAndHasVoiceDesignatable() throws {
        var p = sample()
        p.tracks[0].clips.append(clip("b", start: 8))
        XCTAssertTrue(ClipEditing.hasVoiceDesignatable(["a"], in: p))
        XCTAssertFalse(ClipEditing.hasVoiceDesignatable(["v"], in: p))
        XCTAssertFalse(ClipEditing.hasVoiceDesignatable(["i", "m"], in: p))
        XCTAssertFalse(ClipEditing.hasVoiceDesignatable([], in: p))
        XCTAssertFalse(ClipEditing.allTreatedAsVoice(["a"], in: p))
        XCTAssertFalse(ClipEditing.allTreatedAsVoice(["v"], in: p), "対象が無いときは false")
        let d = try designated(p, "a")
        XCTAssertTrue(ClipEditing.allTreatedAsVoice(["a"], in: d))
        XCTAssertTrue(ClipEditing.allTreatedAsVoice(["a", "v"], in: d), "対象外は数えない")
        XCTAssertFalse(ClipEditing.allTreatedAsVoice(["a", "b"], in: d))
        let c = try designated(compoundProject(), "k1")
        XCTAssertTrue(ClipEditing.hasVoiceDesignatable(["k1"], in: c))
        XCTAssertTrue(ClipEditing.allTreatedAsVoice(["k1"], in: c))
    }

    // MARK: ダッキング統合

    func testDesignatedAudioDucksBgm() throws {
        var p = Project.new()
        var voice = clip("rec", start: 2, dur: 2); voice.treatAsVoice = true
        var bgm = clip("bgm", start: 0, dur: 10); bgm.duck = Duck()
        p.tracks[0].clips = [voice]
        p.tracks[1].clips = [bgm]
        let spans = Ducking.voiceSpans(in: p)
        XCTAssertEqual(spans, [Ducking.Span(start: 2, end: 4)])
        let sr = 1000.0
        let g = Ducking.gains(startFrame: 0, count: 10_000, sr: sr, spans: spans, duck: try XCTUnwrap(bgm.duck))
        XCTAssertLessThan(g[3000], 1, "声の区間では下がる")
        XCTAssertEqual(g[8000], 1, "離れていれば下がらない")
        // 指定を外すと下がらない
        let off = try XCTUnwrap(ClipEditing.setTreatedAsVoice(in: p, clipId: "rec", false))
        let none = Ducking.gains(startFrame: 0, count: 10_000, sr: sr, spans: Ducking.voiceSpans(in: off), duck: Duck())
        XCTAssertEqual(none[3000], 1)
    }
}
