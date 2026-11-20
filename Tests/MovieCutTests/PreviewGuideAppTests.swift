import XCTest
import MovieCutCore
@testable import MovieCut

/// 表示 ▸ ガイド線: 6 項目(セーフ 2・中心線・グリッド 3)、ショートカットなし、出しているものにチェック。
final class PreviewGuideAppTests: XCTestCase {
    func testGuideItemsAreChecksWithoutShortcuts() {
        var s = MenuState(); s.hasDocument = true
        s.previewGuides = [.center]
        let items = AppMenuSpec.guideItems(s)
        XCTAssertEqual(items.map(\.title), PreviewGuide.allCases.map(\.title))
        XCTAssertTrue(items.allSatisfy { $0.shortcut == nil && $0.enabled })
        XCTAssertEqual(items.first { $0.command == .guide(.center) }?.checked, true)
        XCTAssertEqual(items.first { $0.command == .guide(.thirds) }?.checked, false)
    }
}
