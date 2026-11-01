import XCTest
import MovieCutCore
@testable import MovieCut

/// 図形(クリップ ▸ 図形を追加 ▸ 種類): 1 操作 = 1 Undo、一番上のレイヤーに置く、ショートカットなしの項目。
@MainActor
final class ShapeAppTests: XCTestCase {
    private func makeModel() -> ProjectModel {
        var p = Project.new()
        var i = Clip(); i.id = "i"; i.type = .image; i.start = 0; i.duration = 4; i.src = "/tmp/none.png"
        p.tracks[0].clips = [i]
        let m = ProjectModel(project: p)
        m.notices = OneTimeNotices()
        return m
    }

    func testAddShapeIsOneUndoStepOnTopLayerAndSelected() {
        let m = makeModel()
        m.currentTime = 1.5
        AppMenu.perform(.addShape(.arrow), model: m)
        let top = m.project.tracks[m.project.tracks.count - 1].clips.last
        XCTAssertEqual(top?.type, .shape)
        XCTAssertEqual(top?.start, 1.5)
        XCTAssertEqual(top?.figure?.figureKind, .arrow)
        XCTAssertEqual(m.selectedClipId, top?.id)
        XCTAssertEqual(m.effectiveUndoManager.undoActionName, "図形の追加")
        m.effectiveUndoManager.undo()
        XCTAssertFalse(m.project.tracks.flatMap(\.clips).contains { $0.type == .shape })
    }

    func testRectAddWritesNoFigureAtAll() {
        let m = makeModel()
        m.currentTime = 0
        AppMenu.perform(.addShape(.rect), model: m)
        let top = m.project.tracks[m.project.tracks.count - 1].clips.last
        XCTAssertEqual(top?.type, .shape)
        XCTAssertNil(top?.figure, "四角形の既定は項目を書かない")
    }

    func testShapeSubmenuHasFiveKindsWithoutShortcuts() {
        var s = MenuState(); s.hasDocument = true
        let items = AppMenuSpec.shapeItems(s)
        XCTAssertEqual(items.map(\.title), ["四角形", "楕円", "線", "矢印", "星"])
        XCTAssertTrue(items.allSatisfy { $0.shortcut == nil && $0.enabled })
        var locked = MenuState(); locked.hasDocument = true; locked.isLocked = true
        XCTAssertTrue(AppMenuSpec.shapeItems(locked).allSatisfy { !$0.enabled }, "編集できないときは押せない")
    }

    func testInspectorKindChangeIsOneUndoStepAndBackToDefaultRemovesFigure() {
        let m = makeModel()
        m.currentTime = 0
        AppMenu.perform(.addShape(.rect), model: m)
        let id = m.selectedClipId!
        m.setClipProperty({ $0.figure = ClipInspector.figUpdated($0.figure) { $0.kind = "ellipse" } }, name: "図形の種類の変更", clipId: id)
        XCTAssertEqual(m.clip(id)?.figure, Figure(kind: "ellipse"))
        m.setClipProperty({ $0.figure = ClipInspector.figUpdated($0.figure) { $0.kind = "rect" } }, name: "戻す", clipId: id)
        XCTAssertNil(m.clip(id)?.figure, "既定に戻したら項目ごと外れる")
        XCTAssertNil(ClipInspector.figUpdated(nil) { $0.corner = 0 }, "角丸 0 は書かない")
        XCTAssertEqual(ClipInspector.figUpdated(nil) { $0.corner = 0.2 }, Figure(corner: 0.2))
    }
}
