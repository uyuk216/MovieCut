import XCTest
@testable import MovieCut
@testable import MovieCutCore

/// 起動時の画面(ようこそ)の出す・出さないの判断と、一覧の日付の表示。
final class WelcomePolicyTests: XCTestCase {
    private let blank = LaunchDocInfo(isUntitled: true, isPristine: true)
    private let saved = LaunchDocInfo(isUntitled: false, isPristine: true)
    private let dirty = LaunchDocInfo(isUntitled: true, isPristine: false)

    func testShownOnPlainLaunch() {
        XCTAssertTrue(WelcomePolicy.shouldShow(showAtLaunch: true, launchedWithDocuments: false, docs: []))
        XCTAssertTrue(WelcomePolicy.shouldShow(showAtLaunch: true, launchedWithDocuments: false, docs: [blank]))
    }

    func testHiddenWhenDisabledInSettings() {
        XCTAssertFalse(WelcomePolicy.shouldShow(showAtLaunch: false, launchedWithDocuments: false, docs: []))
    }

    func testHiddenWhenLaunchedWithDocumentOrQuiet() {
        XCTAssertFalse(WelcomePolicy.shouldShow(showAtLaunch: true, launchedWithDocuments: true, docs: []))
        XCTAssertFalse(WelcomePolicy.shouldShow(showAtLaunch: true, launchedWithDocuments: false, docs: [], quiet: true))
    }

    func testHiddenWhenAnyRealOrEditedDocumentIsOpen() {
        XCTAssertFalse(WelcomePolicy.shouldShow(showAtLaunch: true, launchedWithDocuments: false, docs: [saved]))
        XCTAssertFalse(WelcomePolicy.shouldShow(showAtLaunch: true, launchedWithDocuments: false, docs: [blank, dirty]))
    }

    func testDateTextAndMissingFormat() {
        XCTAssertEqual(WelcomePolicy.dateText(nil), "")
        var comps = DateComponents(); comps.year = 2026; comps.month = 10; comps.day = 23; comps.hour = 14; comps.minute = 5
        let d = Calendar(identifier: .gregorian).date(from: comps)!
        let text = WelcomePolicy.dateText(d)
        XCTAssertTrue(text.contains("2026年10月23日"), text)
        XCTAssertEqual(WelcomePolicy.missingText, "見つかりません")
    }
}
