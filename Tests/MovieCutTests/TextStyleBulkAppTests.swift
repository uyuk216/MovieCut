import XCTest
import MovieCutCore
@testable import MovieCut

/// スタイルの一括適用(テキスト ▸ スタイルを一括適用): 1 回の Undo、変化なしは登録しない、複数選択の範囲、メニュー項目。
@MainActor
final class TextStyleBulkAppTests: XCTestCase {
    private func text(_ id: String, _ s: String, start: Double = 0) -> Clip {
        var c = Clip(); c.id = id; c.type = .text; c.text = s; c.start = start; c.duration = 2; c.fontSize = 80
        return c
    }

    private func makeModel() -> ProjectModel {
        var p = Project.new()
        p.tracks[0].clips = [text("a", "一"), text("b", "二", start: 3)]
        p.tracks[1].clips = [text("c", "三")]
        return ProjectModel(project: p)
    }

    private var styleId: String { TextStyleLibrary.builtins[1].id }

    func testApplyAllIsOneUndoStep() {
        let m = makeModel()
        let before = m.project
        let n = m.applyTextStyleToAll(id: styleId)
        XCTAssertGreaterThan(n, 0)
        XCTAssertTrue(m.effectiveUndoManager.undoActionName.hasPrefix("スタイルを一括適用"))
        m.effectiveUndoManager.undo()
        XCTAssertEqual(m.project, before)
        XCTAssertFalse(m.effectiveUndoManager.canUndo)
    }

    func testSecondApplyRegistersNothing() {
        let m = makeModel()
        _ = m.applyTextStyleToAll(id: styleId)
        m.effectiveUndoManager.removeAllActions()
        XCTAssertEqual(m.applyTextStyleToAll(id: styleId), 0)
        XCTAssertFalse(m.effectiveUndoManager.canUndo)
    }

    func testMultiSelectionLimitsScope() {
        let m = makeModel()
        m.selectedClipIDs = ["a", "b"]
        m.selectedClipId = "a"
        let before = m.project
        let n = m.applyTextStyleToAll(id: styleId)
        XCTAssertEqual(n, 2)
        XCTAssertNotEqual(m.project.allClips.first { $0.id == "a" }, before.allClips.first { $0.id == "a" })
        XCTAssertNotEqual(m.project.allClips.first { $0.id == "b" }, before.allClips.first { $0.id == "b" })
        XCTAssertEqual(m.project.allClips.first { $0.id == "c" }, before.allClips.first { $0.id == "c" }, "選んでいない文字は変えない")
    }

    func testMenuItemsListEveryTextStyleAndAreDisabledWithoutText() {
        let m = makeModel()
        let s = MenuState(model: m)
        let items = AppMenuSpec.textStyleAllItems(s)
        XCTAssertEqual(items.count, s.textStyleChoices.count)
        XCTAssertTrue(items.allSatisfy { $0.enabled && $0.shortcut == nil })
        let none = ProjectModel(project: Project.new())
        XCTAssertFalse(AppMenuSpec.textStyleAllItems(MenuState(model: none)).contains { $0.enabled })
    }
}
