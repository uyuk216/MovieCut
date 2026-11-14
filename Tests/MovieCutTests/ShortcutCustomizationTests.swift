import XCTest
import SwiftUI
import AppKit
@testable import MovieCut

/// ショートカットのカスタマイズ: 保存(往復)・通常キーの実効マップ(上書きと奪い合い)・メニューの上書き ID。
@MainActor
final class ShortcutCustomizationTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "shortcut-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testStoreRoundTrip() {
        let a = ShortcutStore(defaults: defaults)
        a.setMenuOverride(MenuShortcut(key: "e", modifiers: [.command, .shift]), for: "test-export")
        a.setPlainOverride(.init(keyCode: 7, display: "X"), for: .split)
        let b = ShortcutStore(defaults: defaults)
        XCTAssertEqual(b.menuOverride(for: "test-export")?.display, "⇧⌘E")
        XCTAssertEqual(b.plainOverride(for: .split)?.keyCode, 7)
        XCTAssertEqual(b.plainOverride(for: .split)?.display, "X")
        b.setMenuOverride(nil, for: "test-export")
        b.setPlainOverride(nil, for: .split)
        let c = ShortcutStore(defaults: defaults)
        XCTAssertNil(c.menuOverride(for: "test-export"))
        XCTAssertNil(c.plainOverride(for: .split))
        XCTAssertFalse(c.hasAnyOverride)
    }

    func testEffectiveKeyMapDefaultsMatchKeyMap() {
        let store = ShortcutStore(defaults: defaults)
        XCTAssertEqual(KeyRouter.effectiveKeyMap(store: store), KeyRouter.keyMap,
                       "上書きが無ければ既定の対応表と一致")
    }

    func testEffectiveKeyMapOverrideAndSteal() {
        let store = ShortcutStore(defaults: defaults)
        // 分割を S(1) から X(7) へ
        store.setPlainOverride(.init(keyCode: 7, display: "X"), for: .split)
        var map = KeyRouter.effectiveKeyMap(store: store)
        XCTAssertEqual(map[7], .split)
        XCTAssertNil(map[1], "元のキーは外れる")
        // 再生に End(119) を割り当てると、末尾へ からキーが移る
        store.setPlainOverride(.init(keyCode: 119, display: "End"), for: .playPause)
        map = KeyRouter.effectiveKeyMap(store: store)
        XCTAssertEqual(map[119], .playPause)
        XCTAssertFalse(map.values.contains(.toEnd), "末尾へ はキーなしになる")
        // 削除の上書きは ⌫・⌦ の両方を外す
        store.setPlainOverride(.init(keyCode: 36, display: "⏎"), for: .delete)
        map = KeyRouter.effectiveKeyMap(store: store)
        XCTAssertNil(map[51])
        XCTAssertNil(map[117])
        XCTAssertEqual(map[36], .delete)
    }

    func testKeyRouterCommandUsesInjectedStore() {
        let store = ShortcutStore(defaults: defaults)
        store.setPlainOverride(.init(keyCode: 7, display: "X"), for: .split)
        let old = KeyRouter.shortcutStore
        KeyRouter.shortcutStore = store
        defer { KeyRouter.shortcutStore = old }
        XCTAssertEqual(KeyRouter.command(keyCode: 7, modifiers: [], firstResponder: nil), .split)
        XCTAssertNil(KeyRouter.command(keyCode: 1, modifiers: [], firstResponder: nil))
        // 修飾キーつきは相変わらず対象外
        XCTAssertNil(KeyRouter.command(keyCode: 7, modifiers: [.command], firstResponder: nil))
    }

    func testMenuCommandIdIsStable() {
        // 関連値のないケースはケース名がそのまま ID(保存の互換性のため)
        XCTAssertEqual(ShortcutStore.id(for: .playPause), "playPause")
        XCTAssertEqual(ShortcutStore.id(for: .helpShortcuts), "helpShortcuts")
    }

    func testKeyDisplay() {
        XCTAssertEqual(ShortcutStore.keyDisplay(keyCode: 49, characters: " "), "Space")
        XCTAssertEqual(ShortcutStore.keyDisplay(keyCode: 123, characters: nil), "←")
        XCTAssertEqual(ShortcutStore.keyDisplay(keyCode: 7, characters: "x"), "X")
        XCTAssertEqual(ShortcutStore.eventModifiers([.command, .shift]), [.command, .shift])
        XCTAssertEqual(ShortcutStore.eventModifiers([.numericPad, .function]), [], "矢印キーの付随フラグは修飾キーに数えない")
    }
}
