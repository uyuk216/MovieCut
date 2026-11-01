import XCTest
@testable import MovieCutCore

final class CharacterAnimTests: XCTestCase {
    // MARK: 口パク(ヒステリシス)

    func testMouthGateOpensAboveOpenLevelAndClosesBelowCloseLevel() {
        // 0.025 は「閉じ閾値」より大きく「開き閾値」より小さい: 閉じているなら閉じたまま、開いているなら開いたまま
        let env: [Float] = [0.0, 0.025, 0.05, 0.025, 0.025, 0.019, 0.025, 0.0]
        let s = MouthGate.states(env)
        XCTAssertEqual(s, [false, false, true, true, true, false, false, false])
    }

    func testMouthGateIsDeterministicAndStableAtBoundary() {
        // 閾値ちょうどのゆらぎで細かく開閉しない(ヒステリシス)
        let env: [Float] = (0..<200).map { i in i % 2 == 0 ? 0.031 : 0.021 }
        let s = MouthGate.states(env)
        XCTAssertEqual(s.first, true)
        XCTAssertTrue(s.allSatisfy { $0 }, "開いたあとは 0.021 では閉じない")
        XCTAssertEqual(MouthGate.states(env), s)
    }

    // MARK: まばたき

    func testBlinkScheduleIsDeterministicPerSeed() {
        let a = Blink.starts(seed: "clip-A", until: 600)
        XCTAssertEqual(a, Blink.starts(seed: "clip-A", until: 600))
        XCTAssertNotEqual(a, Blink.starts(seed: "clip-B", until: 600))
    }

    func testBlinkIntervalsAreWithinThreeToFiveSeconds() {
        let starts = Blink.starts(seed: "c1", until: 3600)
        XCTAssertGreaterThan(starts.count, 500)
        XCTAssertGreaterThanOrEqual(starts[0], 3); XCTAssertLessThanOrEqual(starts[0], 5)
        for (a, b) in zip(starts, starts.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b - a, 3 - 1e-9)
            XCTAssertLessThanOrEqual(b - a, 5 + 1e-9)
        }
    }

    func testBlinkClosesEyesForFifteenHundredthsOfASecond() {
        let starts = Blink.starts(seed: "c1", until: 20)
        let first = starts[0]
        XCTAssertFalse(Blink.isClosed(seed: "c1", t: first - 0.01))
        XCTAssertTrue(Blink.isClosed(seed: "c1", t: first + 0.01))
        XCTAssertTrue(Blink.isClosed(seed: "c1", t: first + Blink.duration - 0.001))
        XCTAssertFalse(Blink.isClosed(seed: "c1", t: first + Blink.duration + 0.001))
        XCTAssertFalse(Blink.isClosed(seed: "c1", t: -1))
    }

    // MARK: 表情タグ

    func testExpressionTagIsStrippedFromBody() {
        let r = ExpressionTag.split("[笑顔]こんにちは")
        XCTAssertEqual(r.tag, "笑顔")
        XCTAssertEqual(r.body, "こんにちは")
        XCTAssertEqual(ExpressionTag.body("ふつうのセリフ"), "ふつうのセリフ")
        XCTAssertEqual(ExpressionTag.split("[ ]あ").tag, nil, "空の名前はタグではない")
        XCTAssertEqual(ExpressionTag.body("[ ]あ"), "[ ]あ")
        XCTAssertEqual(ExpressionTag.split("途中[笑顔]は タグ でない").tag, nil)
        XCTAssertEqual(ExpressionTag.split("[a[b]c").tag, nil)
    }

    func testExpressionImageOnlyForKnownTags() {
        let ex = ["笑顔": "/img/smile.png", "怒り": "/img/angry.png"]
        XCTAssertEqual(ExpressionTag.imagePath(for: "[笑顔]やった", in: ex), "/img/smile.png")
        XCTAssertNil(ExpressionTag.imagePath(for: "[未知]やった", in: ex), "未知のタグは通常の立ち絵のまま")
        XCTAssertNil(ExpressionTag.imagePath(for: "[笑顔]やった", in: nil))
        XCTAssertNil(ExpressionTag.imagePath(for: "ふつう", in: ex))
    }

    // MARK: バウンス

    func testBounceScalesWithLevelAndIsZeroInSilence() {
        XCTAssertEqual(Bounce.lift(level: 0), 0)
        XCTAssertEqual(Bounce.scale(level: 0), 1)
        XCTAssertEqual(Bounce.lift(level: 0.2), Bounce.maxOffset, accuracy: 1e-12)
        XCTAssertEqual(Bounce.lift(level: 5), Bounce.maxOffset, accuracy: 1e-12, "上限で頭打ち")
        XCTAssertLessThan(Bounce.lift(level: 0.05), Bounce.lift(level: 0.15))
    }

    // MARK: 保存形式(任意項目・古いファイルは変わらない)

    func testNewCharacterFieldsAreOmittedWhenDefault() throws {
        let c = Character()
        let s = String(decoding: try JSONEncoder().encode(c), as: UTF8.self)
        XCTAssertFalse(s.contains("imgBlink"))
        XCTAssertFalse(s.contains("expressions"))
        XCTAssertFalse(s.contains("bounce"))
    }

    func testNewCharacterFieldsRoundTrip() throws {
        var c = Character()
        c.imgBlink = "/a/blink.png"
        c.expressions = ["笑顔": "/a/smile.png"]
        c.bounce = true
        let data = try JSONEncoder().encode(c)
        let back = try JSONDecoder().decode(Character.self, from: data)
        XCTAssertEqual(back, c)
        XCTAssertEqual(back.expressions?["笑顔"], "/a/smile.png")
    }

    func testEmptyExpressionsAreNotWritten() throws {
        let json = Data(#"{"name":"A","expressions":{}}"#.utf8)
        let c = try JSONDecoder().decode(Character.self, from: json)
        XCTAssertNil(c.expressions)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(c), as: UTF8.self).contains("expressions"))
    }
}
