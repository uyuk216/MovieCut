import XCTest
@testable import MovieCutCore

/// 字幕の決まりごとの確認(目安の警告)。種類ごとの発火と、重なりの番号、プロジェクト経由。
final class SubtitleValidationTests: XCTestCase {
    private func kinds(_ cues: [SubtitleCue]) -> [SubtitleIssue.Kind] {
        SubtitleValidator.validate(cues).map(\.kind)
    }

    func testEmptyAndHealthyHaveNoIssues() {
        XCTAssertTrue(SubtitleValidator.validate([]).isEmpty)
        let ok = [
            SubtitleCue(start: 0, end: 2, text: "こんにちは"),
            SubtitleCue(start: 2.5, end: 5, text: "次の字幕です\n2 行目"),
        ]
        XCTAssertTrue(SubtitleValidator.validate(ok).isEmpty)
    }

    func testInvalidRangeAndEmptyText() {
        XCTAssertEqual(kinds([SubtitleCue(start: 3, end: 3, text: "x")]), [.invalidRange])
        XCTAssertEqual(kinds([SubtitleCue(start: 0, end: 2, text: "  ")]), [.emptyText])
    }

    func testTooShortAndTooLong() {
        XCTAssertEqual(kinds([SubtitleCue(start: 0, end: 0.3, text: "短")]), [.tooShort])
        XCTAssertEqual(kinds([SubtitleCue(start: 0, end: 9, text: "長い表示")]), [.tooLong])
        // 境界ちょうどは問題なし
        XCTAssertTrue(SubtitleValidator.validate([SubtitleCue(start: 0, end: SubtitleValidator.minDuration, text: "境")]).isEmpty)
        XCTAssertTrue(SubtitleValidator.validate([SubtitleCue(start: 0, end: SubtitleValidator.maxDuration, text: "境")]).isEmpty)
    }

    func testLinesAndLength() {
        XCTAssertEqual(kinds([SubtitleCue(start: 0, end: 3, text: "1\n2\n3")]), [.tooManyLines])
        let long = String(repeating: "あ", count: SubtitleValidator.maxLineLength + 1)
        XCTAssertEqual(kinds([SubtitleCue(start: 0, end: 3, text: long)]), [.lineTooLong])
    }

    func testReadingTooFast() {
        // 30 字を 1 秒 = 30 字/秒
        let fast = String(repeating: "あ", count: 30)
        XCTAssertEqual(kinds([SubtitleCue(start: 0, end: 1, text: fast)]), [.lineTooLong, .readingTooFast])
        // 同じ字数でも 3 秒あれば行の長さだけ
        XCTAssertEqual(kinds([SubtitleCue(start: 0, end: 3, text: fast)]), [.lineTooLong])
    }

    func testOverlapReportsLaterCueIndex() {
        let cues = [
            SubtitleCue(start: 5, end: 7, text: "後ろの時刻"),
            SubtitleCue(start: 0, end: 6, text: "前の時刻"),
        ]
        let issues = SubtitleValidator.validate(cues)
        XCTAssertEqual(issues.map(\.kind), [.overlap])
        XCTAssertEqual(issues.first?.cueIndex, 0, "重なっているのは開始が後の件(元の番号 0)")
        // くっついているだけ(終わり = 次の始まり)は重なりではない
        let touching = [SubtitleCue(start: 0, end: 2, text: "a"), SubtitleCue(start: 2, end: 4, text: "b")]
        XCTAssertTrue(SubtitleValidator.validate(touching).isEmpty)
    }

    func testIssuesAreSortedByCueIndex() {
        let cues = [
            SubtitleCue(start: 0, end: 9, text: "長い"),
            SubtitleCue(start: 10, end: 10.2, text: "短い"),
        ]
        XCTAssertEqual(SubtitleValidator.validate(cues).map(\.cueIndex), [0, 1])
    }

    func testValidateProjectUsesExportedCues() {
        var p = Project()
        var c = Clip(); c.type = .voice; c.text = "短い表示に長い文を詰め込んだ字幕です"; c.start = 0; c.duration = 0.3
        var tr = Track(name: "L1"); tr.clips = [c]; p.tracks = [tr]
        let issues = SubtitleValidator.validate(project: p)
        XCTAssertFalse(issues.isEmpty)
        XCTAssertTrue(issues.allSatisfy { $0.cueIndex == 0 })
        XCTAssertTrue(issues.map(\.kind).contains(.tooShort))
    }
}
