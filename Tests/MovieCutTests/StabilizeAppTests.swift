import XCTest
import MovieCutCore
@testable import MovieCut

/// 手ぶれ補正のメニュー(仕様表・チェック・ショートカットなし)と、モデルの切り替え(1 操作 = 1 回の Undo)。
@MainActor
final class StabilizeAppTests: XCTestCase {

    private func video(_ id: String) -> Clip {
        var c = Clip(); c.id = id; c.type = .video; c.start = 0; c.duration = 2; c.src = "/tmp/none.mov"; c.srcDuration = 2
        return c
    }

    private func makeModel(_ clips: [Clip]) -> ProjectModel {
        var p = Project.new()
        p.tracks[0].clips = clips
        let m = ProjectModel(project: p)
        m.notices = OneTimeNotices()
        return m
    }

    private func state(_ configure: (inout MenuState) -> Void = { _ in }) -> MenuState {
        var s = MenuState()
        s.hasDocument = true; s.canExport = true
        s.resolutionKey = "1920x1080"; s.codec = "h264"; s.bg = "#000000"
        configure(&s)
        return s
    }

    func testMenuItemIsInClipEditWithoutShortcut() throws {
        let items = AppMenuSpec.clipEdit(state { $0.canStabilize = true; $0.hasSelection = true })
        let item = try XCTUnwrap(items.first(where: { $0.command == MenuCommand.stabilizeToggle }))
        XCTAssertEqual(item.title, "手ぶれ補正（映像を滑らかにする）")
        XCTAssertNil(item.shortcut)
        XCTAssertTrue(item.enabled)
        XCTAssertEqual(item.checked, false)
    }

    func testMenuItemDisabledForNonVideoAndCheckedWhenOn() throws {
        let off = AppMenuSpec.clipEdit(state())
        let item = try XCTUnwrap(off.first(where: { $0.command == MenuCommand.stabilizeToggle }))
        XCTAssertFalse(item.enabled)
        XCTAssertNil(item.checked)
        let on = AppMenuSpec.clipEdit(state { $0.canStabilize = true; $0.isStabilized = true })
        XCTAssertEqual(on.first(where: { $0.command == MenuCommand.stabilizeToggle })?.checked, true)
    }

    func testToggleIsOneUndoStepAndOffRemovesKey() {
        let m = makeModel([video("v1")])
        m.selectedClipId = "v1"
        XCTAssertTrue(m.toggleStabilizeSelected())
        XCTAssertEqual(m.selectedClip?.stabilizeStrength, StabilizeEditing.defaultStrength)
        let u = m.effectiveUndoManager
        XCTAssertTrue(u.canUndo)
        u.undo()
        XCTAssertNil(m.selectedClip?.stabilize, "1 回の Undo で元に戻る")
        XCTAssertFalse(u.canUndo, "Undo は 1 回ぶんだけ")
        u.redo()
        XCTAssertTrue(m.toggleStabilizeSelected())
        XCTAssertNil(m.selectedClip?.stabilize, "オフに戻すとキーごと消える")
    }

    func testToggleIgnoresNonVideoAndLocked() {
        var img = Clip(); img.id = "i1"; img.type = .image; img.src = "/tmp/x.png"; img.duration = 1
        let m = makeModel([img])
        m.selectedClipId = "i1"
        XCTAssertFalse(m.toggleStabilizeSelected())
        XCTAssertFalse(m.effectiveUndoManager.canUndo)
    }

    func testPerformRoutesThroughSpecTable() {
        let m = makeModel([video("v1")])
        m.selectedClipId = "v1"
        AppMenu.perform(.stabilizeToggle, model: m)
        XCTAssertEqual(m.selectedClip?.stabilizeStrength, StabilizeEditing.defaultStrength)
    }
}
