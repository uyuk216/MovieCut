import XCTest
@testable import MovieCutCore

/// カウントダウンの文字クリップ(TextCounter)。
final class TextCounterTests: XCTestCase {
    func testValueIsLinearAndClamped() {
        let c = TextCounter(from: 10, to: 0)
        XCTAssertEqual(c.value(at: 0, duration: 10), 10, accuracy: 1e-9)
        XCTAssertEqual(c.value(at: 2.5, duration: 10), 7.5, accuracy: 1e-9)
        XCTAssertEqual(c.value(at: 10, duration: 10), 0, accuracy: 1e-9)
        XCTAssertEqual(c.value(at: -3, duration: 10), 10, accuracy: 1e-9)
        XCTAssertEqual(c.value(at: 99, duration: 10), 0, accuracy: 1e-9)
    }

    func testCountDownRoundsUpSoLastSecondShowsOne() {
        let c = TextCounter(from: 10, to: 0)
        XCTAssertEqual(c.text(at: 0, duration: 10), "00:10")
        XCTAssertEqual(c.text(at: 0.5, duration: 10), "00:10")      // 9.95 → 10
        XCTAssertEqual(c.text(at: 1.01, duration: 10), "00:09")     // 8.99 → 9
        XCTAssertEqual(c.text(at: 9.5, duration: 10), "00:01")      // 0.5 → 1(0 になるのは終わりの一瞬)
        XCTAssertEqual(c.text(at: 10, duration: 10), "00:00")
    }

    func testCountUpRoundsDown() {
        let c = TextCounter(from: 0, to: 75)
        XCTAssertEqual(c.text(at: 0, duration: 10), "00:00")
        XCTAssertEqual(c.text(at: 5.9, duration: 10), "00:44")   // 44.25 → 44
        XCTAssertEqual(c.text(at: 10, duration: 10), "01:15")
    }

    func testMinutesAndSecondsFormat() {
        let c = TextCounter(from: 3725, to: 0)
        XCTAssertEqual(c.text(at: 0, duration: 3725), "62:05")
        XCTAssertEqual(TextCounter(from: 10, to: 0, format: "ss").text(at: 0, duration: 10), "10")
    }

    func testUnknownFormatFallsBackToDefault() {
        XCTAssertEqual(TextCounter(from: 5, to: 0, format: "hh").format, TextCounter.defaultFormat)
        XCTAssertEqual(TextCounter(from: -4, to: -1).from, 0)     // 負の数は 0 に
    }

    func testDisplayTextPrefixesTextWhenCounterSet() {
        var c = Clip(); c.type = .text; c.start = 2; c.duration = 10; c.text = "残り "
        XCTAssertEqual(c.displayText(at: 2), "残り ", "カウントダウン無しは text そのもの")
        c.counter = TextCounter(from: 10, to: 0)
        XCTAssertEqual(c.displayText(at: 2), "残り 00:10")
        XCTAssertEqual(c.displayText(at: 7), "残り 00:05")
        var bare = Clip(); bare.type = .text; bare.start = 0; bare.duration = 4
        bare.counter = TextCounter(from: 4, to: 0, format: "ss")
        XCTAssertEqual(bare.displayText(at: 0), "4")
    }

    func testCounterIsOptionalAndRoundTrips() throws {
        var c = Clip(); c.type = .text; c.text = "残り "
        let plain = try JSONEncoder().encode(c)
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("\"counter\""), "未設定はファイルに書かない")
        c.counter = TextCounter(from: 30, to: 0, format: "mm:ss")
        let data = try JSONEncoder().encode(c)
        let back = try JSONDecoder().decode(Clip.self, from: data)
        XCTAssertEqual(back.counter, TextCounter(from: 30, to: 0, format: "mm:ss"))
    }
}
