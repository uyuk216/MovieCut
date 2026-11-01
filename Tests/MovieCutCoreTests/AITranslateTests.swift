import XCTest
@testable import MovieCutCore

/// 字幕の翻訳(AITranslatePrompt)。偽の AI プロバイダ(FakeAIProvider)で、送る文と返事の読み取りを確かめる。
final class AITranslateTests: XCTestCase {
    let cues = [
        SubtitleCue(start: 0, end: 1.5, text: "こんにちは"),
        SubtitleCue(start: 2, end: 3.25, text: "今日は\n晴れです"),
        SubtitleCue(start: 4, end: 5, text: "さようなら"),
    ]

    func testPromptNumbersEachCueAndNamesTheLanguage() throws {
        let p = try AITranslatePrompt.build(cues: cues, language: .english)
        XCTAssertTrue(p.contains("English"))
        XCTAssertTrue(p.contains("1\tこんにちは"))
        XCTAssertTrue(p.contains("2\t今日は 晴れです"), "改行は空白に")
        XCTAssertTrue(p.contains("3\tさようなら"))
    }

    func testBuildRefusesEmptyAndTooLong() {
        XCTAssertThrowsError(try AITranslatePrompt.build(cues: [], language: .korean)) { XCTAssertEqual($0 as? AITranslatePrompt.BuildError, .noCues) }
        let long = [SubtitleCue(start: 0, end: 1, text: String(repeating: "あ", count: AITranslatePrompt.maxInputCharacters + 1))]
        XCTAssertThrowsError(try AITranslatePrompt.build(cues: long, language: .korean)) {
            XCTAssertEqual($0 as? AITranslatePrompt.BuildError, .tooLong(limit: AITranslatePrompt.maxInputCharacters))
        }
    }

    func testParseReadsNumberedLinesAndIgnoresChatter() throws {
        let reply = """
        Here you go:
        1\tHello
        2 | It is sunny today.
        3. Goodbye
        """
        XCTAssertEqual(try AITranslatePrompt.parse(reply, expected: 3), ["Hello", "It is sunny today.", "Goodbye"])
    }

    func testParseAcceptsFencesAndOutOfOrderLines() throws {
        let reply = "```\n3\tBye\n1\tHi\n2\tDay\n```"
        XCTAssertEqual(try AITranslatePrompt.parse(reply, expected: 3), ["Hi", "Day", "Bye"])
    }

    func testMissingNumberIsUnparsable() {
        XCTAssertThrowsError(try AITranslatePrompt.parse("1\tHi\n3\tBye", expected: 3)) {
            guard case AIError.unparsable = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try AITranslatePrompt.parse("ごめんなさい", expected: 2))
    }

    func testTranslatedKeepsTimings() {
        let t = AITranslatePrompt.translated(cues, texts: ["a", "b", "c"])
        XCTAssertEqual(t.map(\.start), [0, 2, 4])
        XCTAssertEqual(t.map(\.end), [1.5, 3.25, 5])
        XCTAssertEqual(t.map(\.text), ["a", "b", "c"])
    }

    func testEndToEndWithFakeProviderAndSRT() async throws {
        let fake = FakeAIProvider(.reply("1\t안녕하세요\n2\t오늘은 맑습니다\n3\t안녕히 가세요"))
        let prompt = try AITranslatePrompt.build(cues: cues, language: .korean)
        let reply = try await fake.complete(prompt)
        XCTAssertEqual(fake.prompts, [prompt], "送ったのはこのプロンプトだけ")
        let out = AITranslatePrompt.translated(cues, texts: try AITranslatePrompt.parse(reply, expected: cues.count))
        let srt = SubtitleFile.format(out, as: .srt)
        XCTAssertTrue(srt.contains("안녕하세요"))
        XCTAssertTrue(srt.contains("00:00:02,000 --> 00:00:03,250"), srt)
    }
}
