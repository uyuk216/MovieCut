import XCTest
@testable import MovieCutCore

/// プロパティ欄まわりの純粋な計算(範囲の丸め・エンジン切り替え・キャラ削除・話者名)。
final class InspectorCoreTests: XCTestCase {
    func testClipFieldClamping() {
        var c = Clip(); c.type = .image
        ClipField.start.apply(-3, to: &c); XCTAssertEqual(c.start, 0)
        ClipField.start.apply(1.23456, to: &c); XCTAssertEqual(c.start, 1.235)
        ClipField.duration.apply(0, to: &c); XCTAssertEqual(c.duration, 0.05)
        ClipField.duration.apply(2.00049, to: &c); XCTAssertEqual(c.duration, 2.0)
        ClipField.x.apply(1.5, to: &c); XCTAssertEqual(c.x, 1)
        ClipField.y.apply(-0.2, to: &c); XCTAssertEqual(c.y, 0)
        ClipField.opacity.apply(9, to: &c); XCTAssertEqual(c.opacity, 1)
        ClipField.volume.apply(5, to: &c); XCTAssertEqual(c.volume, 2)
        ClipField.blur.apply(999, to: &c); XCTAssertEqual(c.blur, 300)
        ClipField.strength.apply(-1, to: &c); XCTAssertEqual(c.strength, 0)
        ClipField.scale.apply(0, to: &c); XCTAssertEqual(c.scale, 0.05)
        ClipField.fontSize.apply(1, to: &c); XCTAssertEqual(c.fontSize, 8)
        ClipField.w.apply(.nan, to: &c); XCTAssertEqual(c.w, 0)
        XCTAssertEqual(ClipField.x.value(of: Clip()), 0.5)       // 未設定は Electron 版の既定
        XCTAssertEqual(ClipField.strength.value(of: Clip()), 24)
    }

    func testCharacterFieldRangesFollowEngine() {
        XCTAssertEqual(CharacterField.speed.clamp(5, engine: "voicevox"), 2)
        XCTAssertEqual(CharacterField.speed.clamp(0.1, engine: "voicevox"), 0.5)
        XCTAssertEqual(CharacterField.speed.clamp(1000, engine: "aquestalk"), 300)
        XCTAssertEqual(CharacterField.speed.clamp(10, engine: "aquestalk"), 50)
        XCTAssertEqual(CharacterField.pitch.clamp(1, engine: "voicevox"), 0.15)
        XCTAssertEqual(CharacterField.pitch.clamp(-1, engine: "voicevox"), -0.15)
        XCTAssertEqual(CharacterField.intonation.clamp(3, engine: "voicevox"), 2)
    }

    func testSwitchEngineConvertsSpeedAndFillsFields() {
        var c = Character()
        c.engine = "aquestalk"; c.voice = "れいむ"; c.speed = 100
        CharacterEditing.switchEngine(&c, to: "voicevox")
        XCTAssertEqual(c.engine, "voicevox")
        XCTAssertEqual(c.speed, 1)            // 100 → 1
        XCTAssertEqual(c.pitch, 0); XCTAssertEqual(c.intonation, 1); XCTAssertEqual(c.speaker, 3)
        c.speed = 1.4                          // VOICEVOX として正しい値は保つ
        CharacterEditing.switchEngine(&c, to: "voicevox")
        XCTAssertEqual(c.speed, 1.4)
        CharacterEditing.switchEngine(&c, to: "aquestalk")
        XCTAssertEqual(c.speed, 100)           // 1.4 → 100
        XCTAssertEqual(c.voice, "れいむ")        // 前の声が残っていればそのまま
        var d = Character(); d.engine = "voicevox"; d.speaker = 5; d.speed = nil
        CharacterEditing.switchEngine(&d, to: "aquestalk")
        XCTAssertEqual(d.speed, 100); XCTAssertEqual(d.voice, "れいむ")   // 声が無ければ先頭のプリセット
        d.speed = 150
        CharacterEditing.switchEngine(&d, to: "aquestalk")
        XCTAssertEqual(d.speed, 150)           // ゆっくり側で正しい値は保つ
    }

    func testDeleteCharacterRemovesVoiceClipsAndGuardsLast() throws {
        var p = Project.new()
        let reimu = p.characters[0], marisa = p.characters[1]
        func voice(_ id: String, _ ch: Character) -> Clip { var c = Clip(); c.id = id; c.type = .voice; c.charId = ch.id; c.duration = 1; return c }
        var other = Clip(); other.id = "t"; other.type = .text
        p.tracks[0].clips = [voice("a", reimu), voice("b", marisa), other]
        p.tracks[1].clips = [voice("c", reimu)]
        let r = try XCTUnwrap(CharacterEditing.delete(charId: reimu.id, in: p))
        XCTAssertEqual(Set(r.removedClipIds), ["a", "c"])
        XCTAssertEqual(r.project.characters.count, 2)
        XCTAssertFalse(r.project.characters.contains { $0.id == reimu.id })
        XCTAssertEqual(r.project.allClips.map(\.id).sorted(), ["b", "t"])
        XCTAssertNil(CharacterEditing.delete(charId: "nope", in: p))
        var one = p; one.characters = [reimu]
        XCTAssertNil(CharacterEditing.delete(charId: reimu.id, in: one))   // 最後の 1 人は消せない
    }

    func testSpeakerChoiceLabelsAndFonts() {
        let list = SpeakerChoice.flatten([
            VoicevoxSpeaker(name: "キャラ2", styles: [VoicevoxStyle(id: 3, name: "ノーマル"), VoicevoxStyle(id: 1, name: "あまあま")]),
            VoicevoxSpeaker(name: "四国めたん", styles: [VoicevoxStyle(id: 2, name: "ノーマル")]),
        ])
        XCTAssertEqual(list.map(\.label), ["キャラ2（ノーマル）", "キャラ2（あまあま）", "四国めたん（ノーマル）"])
        XCTAssertEqual(list.map(\.id), [3, 1, 2])
        XCTAssertEqual(FontChoices.all.count, 7)
        XCTAssertEqual(FontChoices.options(including: "Klee"), FontChoices.all)
        XCTAssertEqual(FontChoices.options(including: "Comic Sans").first, "Comic Sans")
    }
}
