import XCTest
import MovieCutCore
@testable import MovieCut

/// 出力 ▸ サムネイル画像を書き出す…: 画像の書き出しと同じ並びにあり、ショートカットは持たない。
final class ThumbnailAppTests: XCTestCase {
    func testThumbnailItemIsInImageExportWithoutShortcut() {
        var s = MenuState(); s.hasDocument = true
        let items = AppMenuSpec.imageExportItems(s)
        let item = items.first { $0.command == .exportThumbnail }
        XCTAssertEqual(item?.title, "サムネイル画像を書き出す…")
        XCTAssertNil(item?.shortcut)
        XCTAssertEqual(item?.hint, "1280×720")
        XCTAssertTrue(items.contains { $0.command == .exportStill })
    }
}
