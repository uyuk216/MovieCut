import XCTest
import MovieCutCore
@testable import MovieCut

/// 表示 ▸ プレビュー画質: 4 項目(自動・フル・中間・低メモリ)、ショートカットなし、現在の上書きにチェック。
/// 保存先は UserDefaults なので、前の値を戻して本人の設定を汚さない(UI2Tests と同じ流儀)。
@MainActor
final class PreviewTierAppTests: XCTestCase {
    private var saved: String?

    override func setUp() {
        super.setUp()
        saved = UserDefaults.standard.string(forKey: PreviewTierStore.defaultsKey)
        UserDefaults.standard.removeObject(forKey: PreviewTierStore.defaultsKey)
    }

    override func tearDown() {
        if let saved { UserDefaults.standard.set(saved, forKey: PreviewTierStore.defaultsKey) } else { UserDefaults.standard.removeObject(forKey: PreviewTierStore.defaultsKey) }
        super.tearDown()
    }

    func testItemsAreRadiosWithoutShortcuts() {
        var s = MenuState(); s.hasDocument = true
        s.previewTier = .reduced
        let items = AppMenuSpec.previewTierItems(s)
        XCTAssertEqual(items.map(\.title), ["自動", "フル", "中間", "低メモリ"])
        XCTAssertTrue(items.allSatisfy { $0.shortcut == nil && $0.enabled })
        XCTAssertEqual(items.map(\.checked), [false, false, true, false])
    }

    func testDefaultIsAutoWhenNothingIsSaved() {
        XCTAssertEqual(PreviewTierStore.current, .auto)
    }

    func testEffectiveTierFollowsOverrideAndAutoUsesBudget() {
        let gib = MemoryBudget.gib
        let roomy = CacheBudgetManager(limitBytes: 16 * gib)   // 2GB 以上 → 中間
        let tight = CacheBudgetManager(limitBytes: gib / 2)    // 2GB 未満 → 低メモリ
        let unlimited = CacheBudgetManager(limitBytes: nil)    // 上限なし → フル
        XCTAssertEqual(PreviewTierStore.effectiveTier(override: .auto, budget: roomy), .reduced)
        XCTAssertEqual(PreviewTierStore.effectiveTier(override: .auto, budget: tight), .minimal)
        XCTAssertEqual(PreviewTierStore.effectiveTier(override: .auto, budget: unlimited), .full)
        // 上書きは予算に関係なくそのまま効く
        XCTAssertEqual(PreviewTierStore.effectiveTier(override: .full, budget: tight), .full)
        XCTAssertEqual(PreviewTierStore.effectiveTier(override: .reduced, budget: unlimited), .reduced)
        XCTAssertEqual(PreviewTierStore.effectiveTier(override: .minimal, budget: roomy), .minimal)
    }

    func testSetStoresAndNotifies() {
        var notified = 0
        let token = NotificationCenter.default.addObserver(forName: PreviewTierStore.didChange, object: nil, queue: nil) { _ in notified += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        PreviewTierStore.set(.minimal)
        XCTAssertEqual(PreviewTierStore.current, .minimal)
        XCTAssertEqual(notified, 1)
    }

    func testMenuRadioSetsTheStoreWithoutTouchingTheProject() {
        let m = ProjectModel(project: .new())
        let before = m.project
        AppMenu.perform(.previewTier(.full), model: m)
        XCTAssertEqual(PreviewTierStore.current, .full)
        XCTAssertEqual(m.project, before)
        XCTAssertFalse(m.effectiveUndoManager.canUndo)
        XCTAssertEqual(MenuState(model: m).previewTier, .full)
    }
}
