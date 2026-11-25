import XCTest
import SwiftUI
import AppKit
@testable import MovieCut

/// Premiere互換プリセット: 適用・実効マップ・無関係なカスタムの保持・適用前への復元。
@MainActor
final class ShortcutPresetTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "shortcut-preset-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testPresetNotAppliedByDefaultAndDefaultsUnchanged() {
        let store = ShortcutStore(defaults: defaults)
        XCTAssertFalse(store.isPremierePresetApplied)
        XCTAssertFalse(store.hasPrePresetBackup)
        // 既定の実効マップは従来どおり(プリセット専用の4コマンドはキーなし)
        XCTAssertEqual(KeyRouter.effectiveKeyMap(store: store), KeyRouter.keyMap)
    }

    func testApplyPremierePreset() {
        let store = ShortcutStore(defaults: defaults)
        store.applyPremierePreset()
        XCTAssertTrue(store.isPremierePresetApplied)
        let map = KeyRouter.effectiveKeyMap(store: store)
        XCTAssertEqual(map[8], .split, "C = 分割(レーザー)")
        XCTAssertNil(map[1], "S は外れる")
        XCTAssertEqual(map[34], .markIn, "I = 書き出し開始")
        XCTAssertEqual(map[31], .markOut, "O = 書き出し終了")
        XCTAssertEqual(map[12], .rippleHead, "Q = 頭のリップルトリム")
        XCTAssertEqual(map[13], .rippleTail, "W = 尻のリップルトリム")
        // J/K/L・Space は既定のまま
        XCTAssertEqual(map[38], .shuttleBack)
        XCTAssertEqual(map[49], .playPause)
        // メニューの項目: ⌘K = 分割、⇧⌫ = すき間を詰めて削除
        XCTAssertEqual(store.menuOverride(for: ShortcutStore.id(for: .split))?.display, "⌘K")
        XCTAssertEqual(store.menuOverride(for: ShortcutStore.id(for: .rippleDelete))?.display, "⇧⌫")
        // 保存され、読み直しても残る
        let reloaded = ShortcutStore(defaults: defaults)
        XCTAssertTrue(reloaded.isPremierePresetApplied)
        XCTAssertTrue(reloaded.hasPrePresetBackup)
    }

    func testPresetKeepsUnrelatedCustomizations() {
        let store = ShortcutStore(defaults: defaults)
        store.setPlainOverride(.init(keyCode: 7, display: "X"), for: .playPause)
        store.setMenuOverride(MenuShortcut(key: "e", modifiers: [.command, .shift]), for: "test-export")
        store.applyPremierePreset()
        XCTAssertEqual(store.plainOverride(for: .playPause)?.keyCode, 7, "プリセットが触らない割り当ては残る")
        XCTAssertEqual(store.menuOverride(for: "test-export")?.display, "⇧⌘E")
    }

    func testPresetRemovesOtherCommandsHoldingTheSameKey() {
        let store = ShortcutStore(defaults: defaults)
        store.setPlainOverride(.init(keyCode: 8, display: "C"), for: .delete)               // プリセットの「分割 = C」と衝突
        store.setMenuOverride(MenuShortcut(key: "k", modifiers: [.command]), for: "test-export")   // プリセットの「⌘K = 分割」と衝突
        store.applyPremierePreset()
        XCTAssertNil(store.plainOverride(for: .delete), "同じキーを持つ他コマンドの上書きは外れる")
        XCTAssertEqual(store.plainOverride(for: .split)?.keyCode, 8)
        XCTAssertNil(store.menuOverride(for: "test-export"), "同じショートカットを持つ他項目の上書きは外れる")
        XCTAssertEqual(store.menuOverride(for: ShortcutStore.id(for: .split))?.display, "⌘K")
        XCTAssertTrue(store.isPremierePresetApplied)
        let keys = store.plainOverrides.values.map(\.keyCode)
        XCTAssertEqual(keys.count, Set(keys).count, "通常キーの重複がない")
    }

    func testRestorePrePresetBackup() {
        let store = ShortcutStore(defaults: defaults)
        store.setPlainOverride(.init(keyCode: 7, display: "X"), for: .playPause)
        store.applyPremierePreset()
        XCTAssertEqual(store.plainOverride(for: .split)?.keyCode, 8)
        store.restorePrePresetBackup()
        XCTAssertFalse(store.hasPrePresetBackup)
        XCTAssertFalse(store.isPremierePresetApplied)
        XCTAssertNil(store.plainOverride(for: .split), "適用前の状態(分割の上書きなし)に戻る")
        XCTAssertEqual(store.plainOverride(for: .playPause)?.keyCode, 7, "適用前のカスタムも戻る")
        XCTAssertNil(store.menuOverride(for: ShortcutStore.id(for: .split)))
        // 控えが無いときの復元は何もしない
        store.restorePrePresetBackup()
        XCTAssertEqual(store.plainOverride(for: .playPause)?.keyCode, 7)
    }

    func testApplyTwiceKeepsOriginalBackup() {
        let store = ShortcutStore(defaults: defaults)
        store.setPlainOverride(.init(keyCode: 7, display: "X"), for: .playPause)
        store.applyPremierePreset()
        store.setPlainOverride(.init(keyCode: 36, display: "⏎"), for: .delete)
        store.applyPremierePreset()
        store.restorePrePresetBackup()
        XCTAssertNil(store.plainOverride(for: .delete), "控えは最初の適用前のまま")
        XCTAssertEqual(store.plainOverride(for: .playPause)?.keyCode, 7)
    }
}
