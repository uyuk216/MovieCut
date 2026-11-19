import XCTest
@testable import MovieCutCore

/// エッセンシャルサウンド: 種別タグの保存・復元、種別ごとの整音プリセットの適用内容、
/// タグ未使用時の不変(従来のファイル・音の挙動と一致)。
final class EssentialSoundTests: XCTestCase {
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

    // MARK: Codable(タグの保存・復元)

    func testCategoryOmittedByDefaultAndRoundTrips() throws {
        let p = sample()
        XCTAssertFalse(String(decoding: try p.encoded(), as: UTF8.self).contains("audioCategory"), "未分類は書かない")
        for category in AudioCategory.allCases {
            var q = sample()
            q.tracks[0].clips[0].audioCategory = category
            let data = try q.encoded()
            XCTAssertTrue(String(decoding: data, as: UTF8.self).range(of: "\"audioCategory\"\\s*:\\s*\"" + category.rawValue + "\"", options: .regularExpression) != nil, "\(category) が書かれる")
            let back = try Project.decode(from: data)
            XCTAssertEqual(back.tracks[0].clips[0].audioCategory, category)
            XCTAssertNil(back.tracks[0].clips[1].audioCategory)
            XCTAssertEqual(try back.encoded(), data, "往復でバイト一致")
        }
    }

    func testMissingKeyReadsAsNil() throws {
        let back = try Project.decode(from: try sample().encoded())
        XCTAssertNil(back.tracks[0].clips[0].audioCategory)
        XCTAssertFalse(back.tracks[0].clips[0].hasAudioCategory)
    }

    func testUnknownCategoryIsPreservedInExtra() throws {
        for raw in [JSONValue.string("narration"), .number(3)] {
            var c = clip("a")
            c.extra["audioCategory"] = raw
            var p = Project.new(); p.tracks[0].clips = [c]
            let data = try p.encoded()
            let back = try Project.decode(from: data)
            XCTAssertNil(back.tracks[0].clips[0].audioCategory, "知らない種別は種別として読まない")
            XCTAssertEqual(back.tracks[0].clips[0].extra["audioCategory"], raw, "捨てずに書き戻す")
            XCTAssertEqual(try back.encoded(), data)
        }
    }

    // MARK: 種別タグだけの編集

    func testSetCategoryChangesOnlyTheTag() throws {
        var c = clip("a")
        c.audioFx = AudioFx(denoise: 0.2)
        XCTAssertTrue(EssentialSoundEditing.setCategory(&c, .dialogue))
        XCTAssertEqual(c.audioCategory, .dialogue)
        XCTAssertEqual(c.audioFx?.denoiseStrength, 0.2, "整音はしない")
        XCTAssertNil(c.treatAsVoice)
        XCTAssertNil(c.duck)
        XCTAssertFalse(EssentialSoundEditing.setCategory(&c, .dialogue), "同じ種別は変化なし")
        XCTAssertTrue(EssentialSoundEditing.setCategory(&c, nil))
        XCTAssertNil(c.audioCategory)
        XCTAssertEqual(c.audioFx?.denoiseStrength, 0.2, "タグを外してもエフェクトは残る")
    }

    func testSetCategoryClearsStaleExtra() throws {
        var p = sample()
        p.tracks[0].clips[0].extra["audioCategory"] = .string("narration")
        let d = try XCTUnwrap(ClipEditing.setAudioCategory(in: p, clipId: "a", .music))
        XCTAssertEqual(d.tracks[0].clips[0].audioCategory, .music)
        XCTAssertNil(d.tracks[0].clips[0].extra["audioCategory"])
    }

    func testUnsupportedTypesAreRefused() {
        var image = clip("i", .image)
        XCTAssertFalse(EssentialSoundEditing.setCategory(&image, .dialogue))
        XCTAssertFalse(EssentialSoundEditing.applyPreset(&image, category: .dialogue))
        var frozen = clip("m", .video); frozen.freeze = true
        XCTAssertFalse(EssentialSoundEditing.supports(frozen), "フリーズフレームは無音なので対象外")
        XCTAssertNil(ClipEditing.setAudioCategory(in: sample(), clipId: "i", .dialogue))
        XCTAssertNil(ClipEditing.setAudioCategory(in: sample(), clipId: "nope", .dialogue))
        XCTAssertNil(ClipEditing.setAudioCategory(in: sample(), clipId: "a", nil), "変わらなければ nil")
    }

    func testLockedClipOrLayerRefuses() {
        var p = sample()
        p.tracks[0].clips[0].locked = true
        XCTAssertNil(ClipEditing.setAudioCategory(in: p, clipId: "a", .dialogue))
        var q = sample()
        q.tracks[0].locked = true
        XCTAssertNil(ClipEditing.setAudioCategory(in: q, clipId: "a", .dialogue))
        var r = compoundProject()
        r.tracks[0].clips[0].locked = true
        XCTAssertNil(ClipEditing.setAudioCategory(in: r, clipId: "k1", .dialogue))
    }

    func testWorksInsideCompound() throws {
        let d = try XCTUnwrap(ClipEditing.setAudioCategory(in: compoundProject(), clipId: "k2", .sfx))
        XCTAssertEqual(d.tracks[0].clips[0].tracks?[0].clips[1].audioCategory, .sfx)
        XCTAssertNil(d.tracks[0].clips[0].tracks?[0].clips[0].audioCategory)
        let applied = try XCTUnwrap(ClipEditing.applyEssentialSound(in: d, ids: ["k2"]))
        XCTAssertEqual(applied.tracks[0].clips[0].tracks?[0].clips[1].audioFx?.normalize?.targetDb, -3)
    }

    // MARK: 整音プリセットの適用内容

    func testDialoguePreset() {
        var c = clip("a")
        c.duck = Duck()
        XCTAssertTrue(EssentialSoundEditing.applyPreset(&c, category: .dialogue))
        XCTAssertEqual(c.audioCategory, .dialogue)
        XCTAssertEqual(c.treatAsVoice, true, "声として扱うがオンになる")
        XCTAssertTrue(c.isVoiceSource)
        XCTAssertNil(c.duck, "会話クリップ自身はダッキングされない")
        let fx = c.audioFx
        XCTAssertEqual(fx?.denoiseStrength, 0.5)
        XCTAssertEqual(fx?.eq?.lowDb, -3); XCTAssertEqual(fx?.eq?.midDb, 2); XCTAssertEqual(fx?.eq?.highDb, 1)
        XCTAssertEqual(fx?.compressor?.thresholdDb, -18); XCTAssertEqual(fx?.compressor?.ratioValue, 3)
        XCTAssertEqual(fx?.compressor?.makeupDb, 2); XCTAssertEqual(fx?.compressor?.isActive, true)
        XCTAssertEqual(fx?.gateDb, -50)
        XCTAssertEqual(fx?.limiterDb, -1)
        XCTAssertEqual(fx?.normalize?.modeOrDefault, .loudness)
        XCTAssertEqual(fx?.normalize?.targetDb, -16)
        XCTAssertTrue(EssentialSoundEditing.isPresetApplied(c))
        XCTAssertFalse(EssentialSoundEditing.applyPreset(&c, category: .dialogue), "同じプリセットの再適用は変化なし")
    }

    func testMusicPreset() {
        var c = clip("a")
        c.treatAsVoice = true
        c.audioFx = AudioFx(denoise: 0.6)
        XCTAssertTrue(EssentialSoundEditing.applyPreset(&c, category: .music))
        XCTAssertEqual(c.audioCategory, .music)
        XCTAssertNil(c.treatAsVoice, "音楽は声として扱わない")
        XCTAssertFalse(c.isVoiceSource)
        XCTAssertEqual(c.duck?.isActive, true, "ダッキングが付く")
        XCTAssertEqual(c.duck?.amountDb, -12); XCTAssertEqual(c.duck?.attackSeconds, 0.15); XCTAssertEqual(c.duck?.releaseSeconds, 0.5)
        XCTAssertEqual(c.audioFx?.denoiseStrength, 0, "音楽にノイズ除去はかけない")
        XCTAssertEqual(c.audioFx?.normalize?.modeOrDefault, .peak)
        XCTAssertEqual(c.audioFx?.normalize?.targetDb, -1)
        XCTAssertEqual(c.audioFx?.limiterDb, -1)
        XCTAssertTrue(EssentialSoundEditing.isPresetApplied(c))
    }

    func testSfxPreset() {
        var c = clip("a")
        c.treatAsVoice = true
        c.duck = Duck()
        c.audioFx = AudioFx(denoise: 0.4)
        XCTAssertTrue(EssentialSoundEditing.applyPreset(&c, category: .sfx))
        XCTAssertNil(c.treatAsVoice)
        XCTAssertNil(c.duck, "効果音はダッキングされない")
        XCTAssertEqual(c.audioFx?.normalize?.modeOrDefault, .peak)
        XCTAssertEqual(c.audioFx?.normalize?.targetDb, -3)
        XCTAssertEqual(c.audioFx?.limiterDb, -1)
        XCTAssertEqual(c.audioFx?.denoiseStrength, 0.4, "ノイズ除去は触らない")
        XCTAssertTrue(EssentialSoundEditing.isPresetApplied(c))
    }

    func testAmbiencePreset() {
        var c = clip("a")
        var eq = AudioFx.EQ(); eq.low = 1
        c.audioFx = AudioFx(eq: eq)
        XCTAssertTrue(EssentialSoundEditing.applyPreset(&c, category: .ambience))
        XCTAssertEqual(c.duck?.amountDb, -8); XCTAssertEqual(c.duck?.attackSeconds, 0.3); XCTAssertEqual(c.duck?.releaseSeconds, 1.0)
        XCTAssertEqual(c.audioFx?.normalize?.modeOrDefault, .loudness)
        XCTAssertEqual(c.audioFx?.normalize?.targetDb, -23)
        XCTAssertEqual(c.audioFx?.denoiseStrength, 0.3)
        XCTAssertEqual(c.audioFx?.eq?.highDb, -2)
        XCTAssertEqual(c.audioFx?.eq?.lowDb, 1, "他の帯域は残る")
        XCTAssertEqual(c.audioFx?.limiterDb, -1)
        XCTAssertTrue(EssentialSoundEditing.isPresetApplied(c))
    }

    func testPresetPreservesUnrelatedSettings() {
        var c = clip("a")
        c.pan = 0.3; c.volume = 0.8
        c.audioFx = AudioFx(reverb: AudioFx.Reverb(mix: 0.4))
        XCTAssertTrue(EssentialSoundEditing.applyPreset(&c, category: .dialogue))
        XCTAssertEqual(c.pan, 0.3); XCTAssertEqual(c.volume, 0.8)
        XCTAssertEqual(c.audioFx?.reverb?.mix, 0.4, "リバーブは触らない")
    }

    func testVideoAndVoiceClipsGetPartialPresets() {
        var video = clip("m", .video)
        XCTAssertTrue(EssentialSoundEditing.applyPreset(&video, category: .dialogue))
        XCTAssertNil(video.treatAsVoice, "動画には声として扱う指定を付けない")
        XCTAssertEqual(video.audioFx?.denoiseStrength, 0.5)
        var voice = clip("v", .voice)
        XCTAssertTrue(EssentialSoundEditing.applyPreset(&voice, category: .music))
        XCTAssertNil(voice.duck, "ボイスクリップにはダッキングを付けない")
        XCTAssertEqual(voice.audioFx?.normalize?.targetDb, -1)
    }

    func testApplyWithoutCategoryDoesNothing() {
        XCTAssertNil(ClipEditing.applyEssentialSound(in: sample(), ids: ["a"]), "種別が無いクリップには適用しない")
        XCTAssertFalse(EssentialSoundEditing.isPresetApplied(clip("a")))
    }

    func testClearingCategoryAfterApplyKeepsEffectsAndBytesReturn() throws {
        let p = sample()
        let tagged = try XCTUnwrap(ClipEditing.setAudioCategory(in: p, clipId: "a", .dialogue))
        let applied = try XCTUnwrap(ClipEditing.applyEssentialSound(in: tagged, ids: ["a"]))
        XCTAssertNotNil(applied.tracks[0].clips[0].audioFx)
        let cleared = try XCTUnwrap(ClipEditing.setAudioCategory(in: applied, clipId: "a", nil))
        XCTAssertNil(cleared.tracks[0].clips[0].audioCategory)
        XCTAssertNotNil(cleared.tracks[0].clips[0].audioFx, "タグを外しても整音は残る")
        // タグだけ付けて外せば、元のファイルとバイト一致する
        let untagged = try XCTUnwrap(ClipEditing.setAudioCategory(in: tagged, clipId: "a", nil))
        XCTAssertEqual(try untagged.encoded(), try p.encoded())
    }

    // MARK: 未使用時の不変

    func testUntaggedProjectIsByteIdenticalAndVoiceSpansUnchanged() throws {
        let p = sample()
        let data = try p.encoded()
        XCTAssertEqual(try Project.decode(from: data).encoded(), data)
        XCTAssertEqual(Ducking.voiceSpans(in: p), [Ducking.Span(start: 3, end: 5)], "タグが無ければ声の区間は従来どおり")
        // 会話プリセットを適用すると、その音声が声の区間に加わる(既存の treatAsVoice の挙動そのもの)
        let tagged = try XCTUnwrap(ClipEditing.setAudioCategory(in: p, clipId: "a", .dialogue))
        XCTAssertEqual(Ducking.voiceSpans(in: tagged), [Ducking.Span(start: 3, end: 5)], "タグだけでは音の挙動は変わらない")
        let applied = try XCTUnwrap(ClipEditing.applyEssentialSound(in: tagged, ids: ["a"]))
        XCTAssertEqual(Ducking.voiceSpans(in: applied), [Ducking.Span(start: 0, end: 2), Ducking.Span(start: 3, end: 5)])
    }

    func testLabelsAndSummariesExist() {
        XCTAssertEqual(AudioCategory.allCases.count, 4)
        for category in AudioCategory.allCases {
            XCTAssertFalse(category.label.isEmpty)
            XCTAssertFalse(category.presetSummary.isEmpty)
        }
        XCTAssertEqual(AudioCategory.dialogue.label, "会話")
        XCTAssertEqual(AudioCategory.sfx.label, "効果音（SFX）")
    }
}
