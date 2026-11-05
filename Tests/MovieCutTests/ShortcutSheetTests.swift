import XCTest
@testable import MovieCut

/// ヘルプ ▸ キーボードショートカット一覧(AppMenuSpec から作る。読み取り専用)。
@MainActor
final class ShortcutSheetTests: XCTestCase {
    /// 表示に出すべき項目の数と内容は、AppMenuSpec.all のショートカット付きの項目と一致する。
    func testEverySpecShortcutAppearsInTheSheet() {
        let withShortcut = AppMenuSpec.all(MenuState()).filter { $0.shortcut != nil }
        XCTAssertGreaterThan(withShortcut.count, 20, "ショートカットを持つ項目が少なすぎます")
        let rows = ShortcutList.menuRows()
        XCTAssertEqual(rows.count, withShortcut.count)
        for item in withShortcut {
            let display = item.shortcut!.display
            XCTAssertTrue(rows.contains { $0.title == item.title && $0.keys == display }, "一覧に出ていません: \(item.title) \(display)")
        }
    }

    /// 行の並びは AppMenuSpec.all の並び(メニューの順)と同じ。
    func testRowsKeepMenuOrder() {
        let expected = AppMenuSpec.all(MenuState()).compactMap { item in item.shortcut.map { "\(item.title)|\($0.display)" } }
        XCTAssertEqual(ShortcutList.menuRows().map { "\($0.title)|\($0.keys)" }, expected)
    }

    func testSampleShortcutsAreShownAsDisplayed() {
        let rows = ShortcutList.menuRows()
        XCTAssertTrue(rows.contains { $0.title == "MP4 を書き出す…" && $0.keys == "⌘E" })
        XCTAssertTrue(rows.contains { $0.title == "次のマーカーへ" && $0.keys == "⌥⌘↓" })
        XCTAssertTrue(rows.contains { $0.title == "前のマーカーへ" && $0.keys == "⌥⌘↑" })
    }

    /// ショートカットを持たない項目(このシートを開く項目も含む)は一覧に出さない。
    func testItemsWithoutShortcutAreNotListed() {
        let rows = ShortcutList.menuRows()
        XCTAssertFalse(rows.contains { $0.title == "キーボードショートカット一覧" })
        XCTAssertFalse(rows.contains { $0.title == "クリップを分割" && $0.keys == "S" }, "S は通常キー(メニューの項目にショートカットは無い)")
    }

    func testHelpMenuHasTheShortcutSheetItemFirst() {
        let first = AppMenuSpec.help.first?.first
        XCTAssertEqual(first?.command, .helpShortcuts)
        XCTAssertEqual(first?.title, "キーボードショートカット一覧")
        XCTAssertNil(first?.shortcut)
        XCTAssertEqual(first?.enabled, true)
    }

    func testPlainKeysAreListedSeparately() {
        let plain = ShortcutList.plainKeys.map(\.keys)
        XCTAssertEqual(plain, ["Space", "←", "→", "Home", "End", "S", "⌫", "Esc", "J", "K", "⌥ + 端をドラッグ", "⌥⇧ + クリップをドラッグ", "L"])
    }
}
