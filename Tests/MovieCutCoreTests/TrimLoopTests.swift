import XCTest
@testable import MovieCutCore

final class TrimLoopTests: XCTestCase {
    private func r(_ p: Double, _ h: Double, _ d: Double, _ c: ExportRange? = nil) -> ExportRange? {
        TrimLoop.loopRange(playhead: p, halfWidth: h, duration: d, clipRange: c)
    }

    func testMiddleIsSymmetric() {
        for h in TrimLoop.halfWidthChoices {
            XCTAssertEqual(r(10, h, 30), ExportRange(start: 10 - h, end: 10 + h))
        }
    }
    func testPlayheadAtZeroShiftsRight() {
        XCTAssertEqual(r(0, 0.5, 10), ExportRange(start: 0, end: 1))
        XCTAssertEqual(r(0, 2, 10), ExportRange(start: 0, end: 4))
        XCTAssertEqual(r(-3, 1, 10), ExportRange(start: 0, end: 2))
    }
    func testNearEndShiftsLeft() {
        XCTAssertEqual(r(10, 1, 10), ExportRange(start: 8, end: 10))
        XCTAssertEqual(r(9.8, 2, 10), ExportRange(start: 6, end: 10))
        XCTAssertEqual(r(99, 0.5, 10), ExportRange(start: 9, end: 10))
    }
    func testNearStartPartial() {
        XCTAssertEqual(r(0.3, 1, 10), ExportRange(start: 0, end: 2))
    }
    func testProjectShorterThanWindowUsesWhole() {
        XCTAssertEqual(r(1, 2, 3), ExportRange(start: 0, end: 3))
        XCTAssertEqual(r(0, 1, 0.5), ExportRange(start: 0, end: 0.5))
    }
    func testEmptyProjectIsNil() {
        XCTAssertNil(r(0, 1, 0))
        XCTAssertNil(r(0, 1, -1))
        XCTAssertNil(r(0, 1, .nan))
        XCTAssertNil(r(0, 1, 0.0005))
        XCTAssertNil(r(0, 1, 10, ExportRange(start: 1, end: 1)))
    }
    func testBadInputs() {
        XCTAssertNil(r(.nan, 1, 10))
        XCTAssertEqual(r(5, 0, 10), ExportRange(start: 4, end: 6), "半幅 0 は既定に")
        XCTAssertEqual(r(5, -1, 10), ExportRange(start: 4, end: 6))
        XCTAssertEqual(r(5, .infinity, 10), ExportRange(start: 4, end: 6))
    }
    func testClipRangeWins() {
        XCTAssertEqual(r(5, 1, 30, ExportRange(start: 2, end: 2.2)), ExportRange(start: 2, end: 2.2), "窓より短いクリップはそのまま")
        XCTAssertEqual(r(5, 1, 30, ExportRange(start: 2, end: 20)), ExportRange(start: 2, end: 20), "窓より長いクリップもそのまま")
    }
    func testClipRangeClampedToProject() {
        XCTAssertEqual(r(0, 1, 10, ExportRange(start: -2, end: 4)), ExportRange(start: 0, end: 4))
        XCTAssertEqual(r(0, 1, 10, ExportRange(start: 8, end: 15)), ExportRange(start: 8, end: 10))
        XCTAssertNil(r(0, 1, 10, ExportRange(start: 11, end: 15)))
    }
    func testResultAlwaysInsideProject() {
        for p in stride(from: -1.0, through: 12.0, by: 0.37) {
            for h in TrimLoop.halfWidthChoices {
                let x = r(p, h, 10)!
                XCTAssertGreaterThanOrEqual(x.start, 0)
                XCTAssertLessThanOrEqual(x.end, 10 + 1e-9)
                XCTAssertGreaterThan(x.duration, 0)
            }
        }
    }
    func testNormalizedHalfWidth() {
        XCTAssertEqual(TrimLoop.normalizedHalfWidth(2), 2)
        XCTAssertEqual(TrimLoop.normalizedHalfWidth(0.5), 0.5)
        XCTAssertEqual(TrimLoop.normalizedHalfWidth(7), 1)
        XCTAssertEqual(TrimLoop.normalizedHalfWidth(.nan), 1)
    }
}
