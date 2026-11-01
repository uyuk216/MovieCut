import XCTest
import MovieCutCore
@testable import MovieCut

/// インスペクタ・メニューからのカウントダウン(テキスト ▸ カウントダウンにする)。Undo は 1 回、変わらない編集は登録しない。
@MainActor
final class CounterAppTests: XCTestCase {
    /// 元に戻せる回数を数えて、やり直しで戻す。選択は undo で外れるので、`keep` の id を選び直す。
    private func undoSteps(_ m: ProjectModel, keep id: String) -> Int { let u = m.effectiveUndoManager; var n = 0; while u.canUndo { u.undo(); n += 1 }; for _ in 0..<n { u.redo() }; m.selectedClipId = id; return n }

    private func makeTextClip() throws -> ProjectModel {
        let m = ProjectModel(project: .new())
        _ = m.addTextClip()
        XCTAssertNotNil(m.selectedClipId)
        return m
    }

    func testToggleAddsAndRemovesWithOneUndoEach() throws {
        let m = try makeTextClip()
        let id = try XCTUnwrap(m.selectedClipId)
        let before = undoSteps(m, keep: id)
        m.toggleCounterSelected()
        XCTAssertEqual(m.clip(id)?.counter, TextCounter())
        XCTAssertEqual(undoSteps(m, keep: id), before + 1)
        m.toggleCounterSelected()
        XCTAssertNil(m.clip(id)?.counter)
    }

    func testEditCounterOneUndoAndNoOpRegistersNothing() throws {
        let m = try makeTextClip()
        let id = try XCTUnwrap(m.selectedClipId)
        m.toggleCounterSelected()
        let base = undoSteps(m, keep: id)
        m.editCounter({ $0.from = 30 }, name: "テスト", clipId: id)
        XCTAssertEqual(m.clip(id)?.counter?.from, 30)
        XCTAssertEqual(undoSteps(m, keep: id), base + 1)
        let after = undoSteps(m, keep: id)
        m.editCounter({ $0.from = 30 }, name: "テスト", clipId: id)
        m.setCounter(TextCounter(from: 30, to: 0, format: "mm:ss"), name: "テスト", clipId: id)
        XCTAssertEqual(undoSteps(m, keep: id), after, "同じ値は履歴に載せない")
    }

    func testMenuItemCheckedFollowsCounter() throws {
        let m = try makeTextClip()
        var s = MenuState()
        s.hasDocument = true; s.isTextClip = true; s.hasCounter = false
        XCTAssertEqual(AppMenuSpec.textCounterItem(s).title, "カウントダウンにする")
        XCTAssertEqual(AppMenuSpec.textCounterItem(s).checked, false)
        s.hasCounter = true
        XCTAssertEqual(AppMenuSpec.textCounterItem(s).checked, true)
        XCTAssertNil(AppMenuSpec.textCounterItem(s).shortcut)
        XCTAssertFalse(m.project.allClips.isEmpty)
    }
}
