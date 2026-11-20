import XCTest
import MovieCutCore
@testable import MovieCut

/// 表示 ▸ ガイド線: 6 項目(セーフ 2・中心線・グリッド 3)、ショートカットなし、出しているものにチェック。
@MainActor
final class PreviewGuideAppTests: XCTestCase {
    private var savedVisible: Any?
    private var savedGuides: Any?

    override func setUp() {
        super.setUp()
        let d = UserDefaults.standard
        savedVisible = d.object(forKey: PreviewGuideStore.visibleDefaultsKey)
        savedGuides = d.object(forKey: PreviewGuide.defaultsKey)
        d.removeObject(forKey: PreviewGuideStore.visibleDefaultsKey)
        d.removeObject(forKey: PreviewGuide.defaultsKey)
    }

    override func tearDown() {
        let d = UserDefaults.standard
        if let v = savedVisible { d.set(v, forKey: PreviewGuideStore.visibleDefaultsKey) } else { d.removeObject(forKey: PreviewGuideStore.visibleDefaultsKey) }
        if let g = savedGuides { d.set(g, forKey: PreviewGuide.defaultsKey) } else { d.removeObject(forKey: PreviewGuide.defaultsKey) }
        super.tearDown()
    }

    func testGuideItemsAreChecksWithoutShortcuts() {
        var s = MenuState(); s.hasDocument = true
        s.previewGuides = [.center]
        let items = AppMenuSpec.guideItems(s)
        XCTAssertEqual(items.map(\.title), PreviewGuide.allCases.map(\.title))
        XCTAssertTrue(items.allSatisfy { $0.shortcut == nil && $0.enabled })
        XCTAssertEqual(items.first { $0.command == .guide(.center) }?.checked, true)
        XCTAssertEqual(items.first { $0.command == .guide(.thirds) }?.checked, false)
    }

    // MARK: 表示フラグ

    func testVisibilityDefaultIsOnAndSetStoresAndNotifies() {
        XCTAssertTrue(PreviewGuideStore.isVisible, "保存が無ければ ON")
        var notified = 0
        let token = NotificationCenter.default.addObserver(forName: PreviewGuideStore.didChange, object: nil, queue: nil) { _ in notified += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        PreviewGuideStore.setVisible(false)
        XCTAssertFalse(PreviewGuideStore.isVisible)
        XCTAssertEqual(notified, 1)
        PreviewGuideStore.toggleVisibility()
        XCTAssertTrue(PreviewGuideStore.isVisible)
        XCTAssertEqual(notified, 2)
    }

    func testVisibilityMenuItemIsACheckWithoutShortcutAndPerformTogglesWithoutTouchingTheProject() {
        var s = MenuState(); s.hasDocument = true
        s.previewGuidesVisible = true
        let item = AppMenuSpec.previewGuidesVisibilityItem(s)
        XCTAssertEqual(item.title, "ガイド線を表示")
        XCTAssertNil(item.shortcut)
        XCTAssertTrue(item.enabled)
        XCTAssertEqual(item.checked, true)
        s.previewGuidesVisible = false
        XCTAssertEqual(AppMenuSpec.previewGuidesVisibilityItem(s).checked, false)
        XCTAssertTrue(AppMenuSpec.all(s).contains { $0.command == .previewGuidesVisibilityToggle })

        let m = ProjectModel(project: .new())
        let before = m.project
        PreviewGuideStore.setVisible(true)
        AppMenu.perform(.previewGuidesVisibilityToggle, model: m)
        XCTAssertFalse(PreviewGuideStore.isVisible)
        XCTAssertEqual(m.project, before, "書類は変えない")
        XCTAssertFalse(m.effectiveUndoManager.canUndo)
        XCTAssertFalse(MenuState(model: m).previewGuidesVisible)
    }

    func testVisibilityAndKindsAreOrthogonal() {
        PreviewGuideStore.toggle(.center)
        let kinds = PreviewGuideStore.current
        PreviewGuideStore.setVisible(false)
        XCTAssertEqual(PreviewGuideStore.current, kinds, "表示を切り替えても種類は変わらない")
        PreviewGuideStore.setVisible(true)
        XCTAssertEqual(PreviewGuideStore.current, kinds)
        PreviewGuideStore.setVisible(false)
        PreviewGuideStore.toggle(.thirds)
        XCTAssertFalse(PreviewGuideStore.isVisible, "種類を選んでも表示フラグは変わらない")
    }
}
