import XCTest
import MovieCutCore
@testable import MovieCut

final class A08UISheets2Tests: XCTestCase {
    func testNormalizedNoteTrimsAndNilsEmpty() {
        XCTAssertNil(AudioLibrarySheet.normalizedNote("  \n "))
        XCTAssertEqual(AudioLibrarySheet.normalizedNote("  メモ \n"), "メモ")
    }
    func testDurationTextNonFinite() {
        XCTAssertEqual(AudioLibrarySheet.durationText(.nan), "0:00")
        XCTAssertEqual(AudioLibrarySheet.durationText(.infinity), "0:00")
        XCTAssertEqual(AudioLibrarySheet.durationText(65), "1:05")
    }
    func testMetricsKeyChangesWithContent() {
        var c = Clip(); c.id = "a"; c.src = "x.wav"; c.duration = 3
        let k1 = TakeCompareSheet.metricsKey(c)
        c.duration = 2
        XCTAssertNotEqual(k1, TakeCompareSheet.metricsKey(c))
    }
}
