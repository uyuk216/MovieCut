import XCTest
@testable import MovieCutCore

/// 台本編集ウィンドウの土台(#41): ボイスクリップの一覧化と、行編集の適用。
final class ScriptTableTests: XCTestCase {
    private func sampleProject() -> Project {
        var p = Project()
        var c1 = Character(); c1.name = "霊夢"
        var c2 = Character(); c2.name = "魔理沙"
        p.characters = [c1, c2]
        func voice(_ char: Character, _ text: String, _ sub: String?, _ start: Double) -> Clip {
            var c = Clip(); c.type = .voice; c.text = text; c.subtitleText = sub
            c.charId = char.id; c.start = start; c.duration = 2; c.src = "/voices/\(start).wav"
            return c
        }
        var track = Track(name: "ボイス")
        track.clips = [voice(c2, "あと", nil, 5), voice(c1, "[笑顔]こんにちは", nil, 0), voice(c1, "あいぼう", "相棒", 2)]
        var other = Track(name: "映像")
        var img = Clip(); img.type = .image; img.start = 0; img.duration = 3
        other.clips = [img]
        p.tracks = [track, other]
        return p
    }

    func testLinesListsVoicesInStartOrderWithSplitFields() {
        let p = sampleProject()
        let lines = ScriptTable.lines(in: p)
        XCTAssertEqual(lines.count, 3, "ボイスだけ・開始順")
        XCTAssertEqual(lines[0].characterName, "霊夢")
        XCTAssertEqual(lines[0].spoken, "こんにちは")
        XCTAssertEqual(lines[0].expression, "笑顔", "表情タグは本文から分ける")
        XCTAssertNil(lines[0].subtitle)
        XCTAssertEqual(lines[1].spoken, "あいぼう")
        XCTAssertEqual(lines[1].subtitle, "相棒")
        XCTAssertEqual(lines[2].characterName, "魔理沙")
        XCTAssertEqual(lines.map(\.start), [0, 2, 5])
    }

    func testLineNormalizesSubtitleEqualToSpoken() {
        var p = sampleProject()
        var c = Clip(); c.type = .voice; c.text = "同じ"; c.subtitleText = "同じ"; c.charId = p.characters[0].id
        XCTAssertNil(ScriptTable.line(for: c, in: p)?.subtitle, "読み上げ文と同じ字幕は「指定なし」にそろえる")
        var img = Clip(); img.type = .image
        XCTAssertNil(ScriptTable.line(for: img, in: p), "ボイス以外は行にしない")
    }

    func testApplyEditsTextSubtitleExpressionAndCharacter() {
        var p = sampleProject()
        var lines = ScriptTable.lines(in: p)
        lines[0].spoken = "こんばんは"
        lines[0].expression = "怒り"
        lines[0].subtitle = ""
        lines[0].characterId = p.characters[1].id
        lines[0].characterName = p.characters[1].name
        XCTAssertEqual(ScriptTable.apply(lines, to: &p), 1, "変えた行だけ数える")
        let clip = p.allClips.first { $0.id == lines[0].clipId }!
        XCTAssertEqual(clip.text, "[怒り]こんばんは")
        XCTAssertEqual(clip.subtitleText, "", "字幕なしは空文字のまま")
        XCTAssertEqual(clip.charId, p.characters[1].id)
        // 音声まわりは変えない
        XCTAssertEqual(clip.start, 0)
        XCTAssertEqual(clip.duration, 2)
        XCTAssertNotNil(clip.src)
    }

    func testApplySubtitleSameAsSpokenClearsSubtitleText() {
        var p = sampleProject()
        var lines = ScriptTable.lines(in: p)
        lines[1].subtitle = "あいぼう"   // 読み上げ文と同じ字幕を指定
        XCTAssertEqual(ScriptTable.apply([lines[1]], to: &p), 1)
        let clip = p.allClips.first { $0.id == lines[1].clipId }!
        XCTAssertNil(clip.subtitleText, "読み上げ文と同じなら書かない")
    }

    func testApplyRejectsEmptySpokenUnknownClipAndUnknownCharacter() {
        var p = sampleProject()
        let lines = ScriptTable.lines(in: p)
        var empty = lines[0]; empty.spoken = "  "
        XCTAssertFalse(ScriptTable.apply(empty, to: &p), "読み上げ文が空の行は当てない")
        var ghost = lines[0]; ghost.clipId = "no-such-clip"
        XCTAssertFalse(ScriptTable.apply(ghost, to: &p))
        var badChar = lines[0]; badChar.characterId = "no-such-char"; badChar.spoken = "変更"
        XCTAssertTrue(ScriptTable.apply(badChar, to: &p), "キャラが実在しなくても文字の編集は当てる")
        let clip = p.allClips.first { $0.id == lines[0].clipId }!
        XCTAssertEqual(clip.text, "[笑顔]変更", "表情タグは行の指定どおり残る")
        XCTAssertEqual(clip.charId, p.characters[0].id, "実在しないキャラへは付け替えない")
        // 変更なしの行は数えない
        XCTAssertEqual(ScriptTable.apply(ScriptTable.lines(in: p), to: &p), 0)
    }

    func testApplyDoesNotTouchNonVoiceClips() {
        var p = sampleProject()
        let img = p.tracks[1].clips[0]
        let fake = VoiceLine(clipId: img.id, characterId: nil, characterName: "", spoken: "x",
                             expression: "", subtitle: nil, start: 0, duration: 3)
        XCTAssertFalse(ScriptTable.apply(fake, to: &p))
        XCTAssertEqual(p.tracks[1].clips[0], img)
    }
}
