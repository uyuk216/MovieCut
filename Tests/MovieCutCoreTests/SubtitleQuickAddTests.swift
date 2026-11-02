import XCTest
@testable import MovieCutCore

/// 「字幕を追加…」の置き場所・既定の長さ・空の本文・直し。
final class SubtitleQuickAddTests: XCTestCase {
    private func textClip(_ start: Double, _ dur: Double, _ text: String) -> Clip {
        var c = Clip(); c.type = .text; c.start = start; c.duration = dur; c.text = text; return c
    }

    func testEmptyTextIsNoOp() {
        let p = Project.new()
        XCTAssertNil(SubtitleQuickAdd.add(text: "   \n ", at: 1, to: p))
        XCTAssertNil(SubtitleQuickAdd.updateText(clipId: "x", text: "", in: p))
    }

    func testDefaultDurationIsThreeSecondsAndStartsAtPlayhead() {
        let r = SubtitleQuickAdd.add(text: "こんにちは", at: 4.5, to: Project.new())!
        let track = r.project.tracks[r.trackIndex]
        XCTAssertEqual(track.name, "字幕")
        let c = track.clips.first { $0.id == r.clipId }!
        XCTAssertEqual(c.start, 4.5, accuracy: 1e-9)
        XCTAssertEqual(c.duration, 3, accuracy: 1e-9)
        XCTAssertEqual(c.text, "こんにちは")
        XCTAssertEqual(c.type, .text)
    }

    func testMultilineTextKeepsInnerNewlinesAndTrimsEdges() {
        XCTAssertEqual(SubtitleQuickAdd.cleanedText("\n 一行目\n二行目 \n"), "一行目\n二行目")
    }

    func testReusesFreeUnlockedSubtitleLayer() {
        var p = Project.new()
        var sub = Track(name: "字幕"); sub.clips = [textClip(0, 2, "前")]
        p.tracks.append(sub)
        let n = p.tracks.count
        let r = SubtitleQuickAdd.add(text: "後", at: 5, to: p)!
        XCTAssertEqual(r.project.tracks.count, n, "空きがあるので新しいレイヤーは作らない")
        XCTAssertEqual(r.trackIndex, n - 1)
    }

    func testOverlapMovesToNewNumberedLayerAndLockedIsSkipped() {
        var p = Project.new()
        var locked = Track(name: "字幕"); locked.locked = true
        var busy = Track(name: "字幕 2"); busy.clips = [textClip(4, 4, "重なる")]
        p.tracks += [locked, busy]
        let r = SubtitleQuickAdd.add(text: "新", at: 5, to: p)!
        XCTAssertEqual(r.project.tracks.last?.name, "字幕 3", "ロック・重なりを避けて新しい番号のレイヤー")
        XCTAssertEqual(r.project.tracks.last?.clips.map(\.text), ["新"])
        XCTAssertEqual(r.project.tracks[1].clips.count, 0)
    }

    func testFirstLayerNameIsPlainSubtitleWhenAbsent() {
        let r = SubtitleQuickAdd.add(text: "a", at: 0, to: Project.new())!
        XCTAssertEqual(r.project.tracks.last?.name, "字幕")
    }

    func testDurationIsClampedAndNonFiniteFallsBack() {
        XCTAssertEqual(SubtitleQuickAdd.clampDuration(0), 0.1, accuracy: 1e-9)
        XCTAssertEqual(SubtitleQuickAdd.clampDuration(.nan), 3, accuracy: 1e-9)
        XCTAssertEqual(SubtitleQuickAdd.clampDuration(10_000), 600, accuracy: 1e-9)
    }

    func testStyleIsAppliedWhenGiven() {
        let style = TextStyleLibrary.builtins.first { $0.id == "builtin.classic" }?.look
        XCTAssertNotNil(style)
        let r = SubtitleQuickAdd.add(text: "字", at: 0, style: style, to: Project.new())!
        let c = r.project.tracks[r.trackIndex].clips[0]
        XCTAssertEqual(c.color, style?.color, "字幕の文字スタイルの色を当てる")
    }

    func testUpdateTextKeepsPlaceAndChangesOnlyWhatIsGiven() {
        var p = Project.new()
        var sub = Track(name: "字幕"); sub.clips = [textClip(1, 2, "古い")]
        p.tracks.append(sub)
        let id = sub.clips[0].id
        let u = SubtitleQuickAdd.updateText(clipId: id, text: "新しい", in: p)!
        let c = u.tracks.last!.clips[0]
        XCTAssertEqual(c.text, "新しい")
        XCTAssertEqual(c.duration, 2, accuracy: 1e-9, "長さを省けば変えない")
        XCTAssertEqual(c.start, 1, accuracy: 1e-9)
        let d = SubtitleQuickAdd.updateText(clipId: id, text: "新", duration: 5, in: p)!
        XCTAssertEqual(d.tracks.last!.clips[0].duration, 5, accuracy: 1e-9)
    }

    func testUpdateUnknownIdIsNil() {
        XCTAssertNil(SubtitleQuickAdd.updateText(clipId: "nope", text: "x", in: Project.new()))
    }
}
