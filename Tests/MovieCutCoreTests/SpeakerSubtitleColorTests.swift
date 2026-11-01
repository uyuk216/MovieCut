import XCTest
@testable import MovieCutCore

/// キャラごとの字幕の文字色(Character.subtitleColor)。字幕の自動生成が、セリフのキャラの色を文字の色に使う。
final class SpeakerSubtitleColorTests: XCTestCase {
    private func voice(_ start: Double, _ dur: Double, _ text: String, charId: String?) -> Clip {
        var c = Clip()
        c.type = .voice
        c.start = start; c.duration = dur; c.text = text; c.charId = charId
        return c
    }

    private func project(_ clips: [Clip], characters: [Character]) -> Project {
        var p = Project.new()
        var t = Track(name: "声")
        t.clips = clips
        p.tracks = [t]
        p.characters = characters
        return p
    }

    private func character(_ id: String, color: String?) -> Character {
        var c = Character()
        c.id = id
        c.subtitleColor = color
        return c
    }

    func testNormalizesHexAndRejectsOtherShapes() {
        XCTAssertEqual(SpeakerSubtitleColor.normalized("#FF8800"), "#ff8800")
        XCTAssertEqual(SpeakerSubtitleColor.normalized("  #aabbcc "), "#aabbcc")
        XCTAssertNil(SpeakerSubtitleColor.normalized("ff8800"))
        XCTAssertNil(SpeakerSubtitleColor.normalized("#ff88"))
        XCTAssertNil(SpeakerSubtitleColor.normalized("#gg0000"))
        XCTAssertNil(SpeakerSubtitleColor.normalized(nil))
    }

    func testGenerationUsesSpeakerColorAndKeepsDefaultForOthers() throws {
        let p = project([voice(0, 2, "赤いセリフ", charId: "red"), voice(3, 1, "ふつう", charId: "plain"), voice(5, 1, "無所属", charId: nil)],
                        characters: [character("red", color: "#FF0000"), character("plain", color: nil)])
        let r = try XCTUnwrap(SubtitleGeneration.generate(p, style: nil))
        let subs = r.project.tracks.last?.clips ?? []
        XCTAssertEqual(subs.count, 3)
        XCTAssertEqual(subs[0].color, "#ff0000")
        XCTAssertEqual(subs[1].color, "#ffffff", "色の無いキャラは従来どおり")
        XCTAssertEqual(subs[2].color, "#ffffff")
    }

    func testSpeakerColorWinsOverTextStyleColor() throws {
        var look = TextLook()
        look.color = "#00ff00"
        let p = project([voice(0, 2, "こんにちは", charId: "red")], characters: [character("red", color: "#0000ff")])
        let r = try XCTUnwrap(SubtitleGeneration.generate(p, style: look))
        XCTAssertEqual(r.project.tracks.last?.clips.first?.color, "#0000ff")
    }

    func testCodecOmitsNilAndRoundTrips() throws {
        let plain = try JSONEncoder().encode(character("a", color: nil))
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("subtitleColor"))
        let colored = try JSONEncoder().encode(character("a", color: "#123456"))
        let back = try JSONDecoder().decode(Character.self, from: colored)
        XCTAssertEqual(back.subtitleColor, "#123456")
        XCTAssertFalse(back.extra.keys.contains("subtitleColor"), "既知の項目として読む(extra に重複させない)")
    }
}
