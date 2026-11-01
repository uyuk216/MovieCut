import XCTest
@testable import MovieCutCore

/// 範囲ループ再生の時刻の決め方。
final class ExportRangeLoopTests: XCTestCase {
    private let r = ExportRange(start: 2, end: 5)

    func testStartInsideRangeKeepsTime() {
        XCTAssertEqual(ExportRangeLoop.startTime(current: 3, range: r), 3)
    }

    func testStartOutsideRangeGoesToHead() {
        XCTAssertEqual(ExportRangeLoop.startTime(current: 0, range: r), 2, "頭より前")
        XCTAssertEqual(ExportRangeLoop.startTime(current: 5, range: r), 2, "終わりにいたら頭から")
        XCTAssertEqual(ExportRangeLoop.startTime(current: 9, range: r), 2, "終わりより後ろ")
    }

    func testWrapOnlyAtOrAfterEnd() {
        XCTAssertNil(ExportRangeLoop.wrap(4.99, range: r))
        XCTAssertEqual(ExportRangeLoop.wrap(5, range: r), 2)
        XCTAssertEqual(ExportRangeLoop.wrap(5.2, range: r), 2)
    }
}
