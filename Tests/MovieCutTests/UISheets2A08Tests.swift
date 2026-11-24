import XCTest
@testable import MovieCut

final class UISheets2A08Tests: XCTestCase {
    func testClampLag() {
        XCTAssertEqual(MulticamCreateSheet.clampLag(1e12), 3600)
        XCTAssertEqual(MulticamCreateSheet.clampLag(-1e12), -3600)
        XCTAssertEqual(MulticamCreateSheet.clampLag(1.5), 1.5)
    }
    func testCurveFieldUnchangedDoesNotCommit() {
        XCTAssertFalse(CurveNumField.shouldCommit(text: NumField.format(0.123456, decimals: 3), current: 0.123456))
        XCTAssertTrue(CurveNumField.shouldCommit(text: "0.5", current: 0.123456))
    }
}
