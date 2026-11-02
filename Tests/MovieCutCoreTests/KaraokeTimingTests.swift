import XCTest
@testable import MovieCutCore

/// 文字起こしの単語時刻 → カラオケ字幕の `Highlight.times`。
final class KaraokeTimingTests: XCTestCase {
    private func w(_ t: String, _ s: Double, _ e: Double) -> TranscriptSegment { TranscriptSegment(text: t, start: s, end: e) }

    func testCharModeSplitsEachWordEvenly() throws {
        let words = [w("こんにちは", 1.0, 2.0), w("世界", 2.0, 3.0)]
        let t = try XCTUnwrap(KaraokeTiming.times(text: "こんにちは世界", words: words, windowStart: 1.0, duration: 2.0, wordMode: false))
        XCTAssertEqual(t.count, 7)
        XCTAssertEqual(t[0], 0, accuracy: 1e-9)
        XCTAssertEqual(t[1], 0.2, accuracy: 1e-9)
        XCTAssertEqual(t[5], 1.0, accuracy: 1e-9)
        XCTAssertEqual(t[6], 1.5, accuracy: 1e-9)
    }

    func testWordModeUsesFirstCharOfEachUnit() throws {
        let words = [w("Hello", 0, 1), w("big", 1.2, 1.6), w("world", 2, 3)]
        let t = try XCTUnwrap(KaraokeTiming.times(text: "Hello big world", words: words, windowStart: 0, duration: 3, wordMode: true))
        XCTAssertEqual(t, [0, 1.2, 2.0])
    }

    func testWhitespaceColorsWithPreviousChar() throws {
        let words = [w("a", 0, 1), w("b", 1, 2)]
        let t = try XCTUnwrap(KaraokeTiming.times(text: "a b", words: words, windowStart: 0, duration: 2, wordMode: false))
        XCTAssertEqual(t, [0, 0, 1])
    }

    func testMismatchReturnsNilSoFallbackIsUsed() {
        let words = [w("こんにちは", 0, 1)]
        XCTAssertNil(KaraokeTiming.times(text: "こんばんは", words: words, windowStart: 0, duration: 1, wordMode: false))
    }

    func testClampingAndMonotonic() throws {
        let words = [w("あ", -0.2, 0.3), w("い", 0.1, 0.3), w("う", 0.9, 1.1)]
        let t = try XCTUnwrap(KaraokeTiming.times(text: "あいう", words: words, windowStart: 0, duration: 1, wordMode: false))
        XCTAssertEqual(t.count, 3)
        XCTAssertTrue(t.allSatisfy { $0 >= 0 && $0 <= 1 })
        XCTAssertEqual(t, t.sorted())
        XCTAssertEqual(t[0], 0)
    }

    func testEmptyAndInvalidInputReturnNil() {
        XCTAssertNil(KaraokeTiming.times(text: "あ", words: [], windowStart: 0, duration: 1, wordMode: false))
        XCTAssertNil(KaraokeTiming.times(text: "あ", words: [w("あ", 0, 1)], windowStart: 0, duration: 0, wordMode: false))
        XCTAssertNil(KaraokeTiming.times(text: "あ", words: [w("あ", .nan, 1)], windowStart: 0, duration: 1, wordMode: false))
        XCTAssertNil(KaraokeTiming.times(text: "あ", words: [w("あ", 0, 1)], windowStart: .nan, duration: 1, wordMode: false))
    }

    func testWordsOutsideWindowAreIgnored() throws {
        let words = [w("前", 0, 1), w("本文", 5, 6), w("後", 9, 10)]
        let t = try XCTUnwrap(KaraokeTiming.times(text: "本文", words: words, windowStart: 5, duration: 1, wordMode: false))
        XCTAssertEqual(t, [0, 0.5])
    }

    func testPhrasesCarryWordTimings() {
        let words = [w("あ", 0, 0.2), w("い", 0.2, 0.4), w("う", 3, 3.2)]
        let p = TranscriptGrouping.phrases(from: words)
        XCTAssertEqual(p.count, 2)
        XCTAssertEqual(p[0].words.map(\.text), ["あ", "い"])
        XCTAssertEqual(p[1].words.map(\.start), [3])
    }

    func testHighlightTimesRoundTripAndOmittedWhenNil() throws {
        let h = Highlight(color: "#ff0000", mode: "char", times: [0, 0.25, 0.5])
        let back = try JSONDecoder().decode(Highlight.self, from: JSONEncoder().encode(h))
        XCTAssertEqual(back, h)
        let none = try JSONEncoder().encode(Highlight(color: "#ff0000"))
        XCTAssertFalse(String(decoding: none, as: UTF8.self).contains("times"))
    }

    private func project() -> Project { Project() }

    func testAppendCuesSetsTimesOnlyWhenStyleHasHighlight() throws {
        let cue = SubtitleCue(start: 1, end: 3, text: "あいう")
        let hook: (SubtitleCue, Highlight) -> [Double]? = { _, _ in [0, 0.5, 1] }
        var look = TextLook(color: "#ffffff", outline: "#000000", font: nil, style: nil, bubble: nil)
        var st = TextStyle(); st.highlight = Highlight(color: "#ffd54a", mode: "char"); look.style = st
        let withHL = try XCTUnwrap(SubtitleGeneration.appendCues([cue], to: project(), style: look, highlightTimes: hook))
        let clip = try XCTUnwrap(withHL.project.tracks.flatMap(\.clips).first { $0.type == .text })
        XCTAssertEqual(clip.textStyle?.highlight?.times, [0, 0.5, 1])

        let plain = TextLook(color: "#ffffff", outline: "#000000", font: nil, style: nil, bubble: nil)
        let noHL = try XCTUnwrap(SubtitleGeneration.appendCues([cue], to: project(), style: plain, highlightTimes: hook))
        let c2 = try XCTUnwrap(noHL.project.tracks.flatMap(\.clips).first { $0.type == .text })
        XCTAssertNil(c2.textStyle?.highlight)
        let base = try XCTUnwrap(SubtitleGeneration.appendCues([cue], to: project(), style: plain))
        let cb = try XCTUnwrap(base.project.tracks.flatMap(\.clips).first { $0.type == .text })
        XCTAssertEqual(c2.textStyle, cb.textStyle, "カラオケが無ければ従来と同じ")
    }
}
