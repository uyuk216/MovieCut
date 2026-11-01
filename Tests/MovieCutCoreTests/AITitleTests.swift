import XCTest
@testable import MovieCutCore

/// タイトル案のプロンプトと返事の読み取り(偽の AI プロバイダで流す)。
final class AITitleTests: XCTestCase {
    private let cues = [SubtitleCue(start: 0, end: 2, text: "今日は雨の街を歩きます"), SubtitleCue(start: 2, end: 4, text: "ラーメンを食べました")]

    func testPromptHasCountRulesCuesAndMarkers() {
        let built = AITitlePrompt.build(cues: cues, markerNames: ["散歩", "", "食事"])
        XCTAssertFalse(built.truncated)
        XCTAssertTrue(built.prompt.contains("\(AITitlePrompt.count) 件"))
        XCTAssertTrue(built.prompt.contains("\(AITitlePrompt.maxTitleLength) 文字以内"))
        XCTAssertTrue(built.prompt.contains("今日は雨の街を歩きます\nラーメンを食べました"))
        XCTAssertTrue(built.prompt.contains("- 散歩\n- 食事"))
        XCTAssertFalse(built.prompt.contains("- \n"), "空の名前は送らない")
    }

    func testPromptWithoutCuesOrMarkersSaysNone() {
        let built = AITitlePrompt.build(cues: [], markerNames: [])
        XCTAssertTrue(built.prompt.contains("(なし)"))
    }

    func testLongInputIsTruncatedAndFlagged() {
        let long = (0..<2000).map { SubtitleCue(start: Double($0), end: Double($0) + 1, text: "字幕の文章のかたまりです") }
        let built = AITitlePrompt.build(cues: long, markerNames: [])
        XCTAssertTrue(built.truncated)
        XCTAssertLessThan(built.prompt.count, AITitlePrompt.maxInputCharacters + 1_000)
    }

    func testParseStripsBulletsNumbersAndQuotes() throws {
        let reply = """
        ```
        1. 雨の街をひとり歩き
        - 「ラーメン旅 第一話」
        3) 'ふらり散歩'
        ```
        """
        XCTAssertEqual(try AITitlePrompt.parse(reply), ["雨の街をひとり歩き", "ラーメン旅 第一話", "ふらり散歩"])
    }

    func testParseDedupesAndLimitsToCount() throws {
        let lines = (1...9).map { "案\($0)" }.joined(separator: "\n") + "\n案1"
        let out = try AITitlePrompt.parse(lines)
        XCTAssertEqual(out.count, AITitlePrompt.count)
        XCTAssertEqual(out.first, "案1")
        XCTAssertEqual(Set(out).count, out.count)
    }

    func testParseEmptyThrows() {
        XCTAssertThrowsError(try AITitlePrompt.parse(" \n \n"))
    }

    func testFakeProviderRoundTrip() async throws {
        let f = FakeAIProvider(.reply("1. 雨の街\n2. ラーメン"))
        let built = AITitlePrompt.build(cues: cues, markerNames: [])
        let reply = try await f.complete(built.prompt)
        XCTAssertEqual(try AITitlePrompt.parse(reply), ["雨の街", "ラーメン"])
        XCTAssertEqual(f.prompts, [built.prompt])
    }
}
