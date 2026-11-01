import XCTest
@testable import MovieCutCore

/// B-3 残り: 台本(ボイス)から字幕の文字クリップを作る。
final class SubtitleGenerationTests: XCTestCase {
    private func voice(_ start: Double, _ dur: Double, _ text: String, subtitle: Bool? = nil) -> Clip {
        var c = Clip()
        c.type = .voice
        c.start = start; c.duration = dur; c.text = text; c.subtitle = subtitle
        return c
    }

    private func project(_ clips: [Clip], hidden: Bool = false, locked: Bool = false) -> Project {
        var p = Project.new()
        var t = Track(name: "声")
        t.clips = clips
        if hidden { t.hidden = true }
        if locked { t.locked = true }
        p.tracks = [t]
        return p
    }

    func testMakesOneTextClipPerVoiceAtSameTime() throws {
        let p = project([voice(0, 2, "こんにちは"), voice(3, 1.5, "さようなら")])
        let r = try XCTUnwrap(SubtitleGeneration.generate(p, style: nil))
        XCTAssertEqual(r.count, 2)
        let subs = SubtitleFile.cues(from: r.project)
        XCTAssertEqual(subs, [SubtitleCue(start: 0, end: 2, text: "こんにちは"), SubtitleCue(start: 3, end: 4.5, text: "さようなら")])
        XCTAssertEqual(r.project.tracks.last?.name, SubtitleFile.layerName)
    }

    func testVoiceSubtitleIsTurnedOffSoItIsNotDrawnTwice() throws {
        let r = try XCTUnwrap(SubtitleGeneration.generate(project([voice(0, 1, "あ")]), style: nil))
        XCTAssertEqual(r.project.tracks[0].clips[0].subtitle, false)
        XCTAssertNil(SubtitleGeneration.generate(r.project, style: nil), "2 回目は何も足さない(冪等)")
        XCTAssertFalse(SubtitleGeneration.hasTargets(r.project))
    }

    func testSkipsEmptyZeroLengthOptOutHiddenAndLocked() {
        let p = project([voice(0, 1, "   "), voice(1, 0, "長さ0"), voice(2, 1, "字幕オフ", subtitle: false)])
        XCTAssertNil(SubtitleGeneration.generate(p, style: nil))
        XCTAssertNil(SubtitleGeneration.generate(project([voice(0, 1, "隠れ")], hidden: true), style: nil))
        XCTAssertNil(SubtitleGeneration.generate(project([voice(0, 1, "ロック")], locked: true), style: nil))
    }

    func testNonVoiceClipsAreNotTouched() {
        var t = Clip(); t.type = .text; t.text = "文字"; t.duration = 1
        var p = Project.new(); var tr = Track(name: "文字"); tr.clips = [t]; p.tracks = [tr]
        XCTAssertNil(SubtitleGeneration.generate(p, style: nil))
    }

    func testOverlappingVoicesGoToSeparateLayers() throws {
        let p = project([voice(0, 3, "A"), voice(1, 1, "B"), voice(4, 1, "C")])
        let r = try XCTUnwrap(SubtitleGeneration.generate(p, style: nil))
        let names = r.project.tracks.dropFirst().map(\.name)
        XCTAssertEqual(names, ["字幕", "字幕 2"])
        XCTAssertEqual(r.project.tracks[1].clips.map(\.text), ["A", "C"])
        XCTAssertEqual(r.project.tracks[2].clips.map(\.text), ["B"])
    }

    func testAppliesStyleLook() throws {
        let look = TextLook(color: "#123456", outline: "#abcdef")
        let r = try XCTUnwrap(SubtitleGeneration.generate(project([voice(0, 1, "あ")]), style: look))
        let clip = try XCTUnwrap(r.project.tracks.last?.clips.first)
        XCTAssertEqual(clip.color, "#123456")
        XCTAssertEqual(clip.outline, "#abcdef")
    }

    func testVoiceClipsWithoutStyleOrSubtitleKeepOtherFieldsUnchanged() throws {
        var v = voice(0, 1, "あ")
        v.volume = 0.5
        let r = try XCTUnwrap(SubtitleGeneration.generate(project([v]), style: nil))
        var expected = v; expected.subtitle = false
        XCTAssertEqual(r.project.tracks[0].clips[0], expected)
    }
}
