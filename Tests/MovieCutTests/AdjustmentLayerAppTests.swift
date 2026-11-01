import XCTest
import MovieCutCore
@testable import MovieCut

/// 調整レイヤー(クリップ ▸ 調整レイヤーを追加): 1 操作 = 1 Undo、一番上のレイヤーに置く、メニューの項目。
@MainActor
final class AdjustmentLayerAppTests: XCTestCase {
    private func makeModel() -> ProjectModel {
        var p = Project.new()
        var i = Clip(); i.id = "i"; i.type = .image; i.start = 0; i.duration = 4; i.src = "/tmp/none.png"
        p.tracks[0].clips = [i]
        let m = ProjectModel(project: p)
        m.notices = OneTimeNotices()
        return m
    }

    func testAddAdjustmentIsOneUndoStepOnTopLayerAndSelected() {
        let m = makeModel()
        m.currentTime = 1.5
        AppMenu.perform(.addAdjustment, model: m)
        let top = m.project.tracks[m.project.tracks.count - 1].clips.last
        XCTAssertEqual(top?.type, .adjustment)
        XCTAssertEqual(top?.start, 1.5)
        XCTAssertEqual(m.selectedClipId, top?.id)
        XCTAssertEqual(m.effectiveUndoManager.undoActionName, "調整レイヤーの追加")
        m.effectiveUndoManager.undo()
        XCTAssertFalse(m.project.tracks.flatMap(\.clips).contains { $0.type == .adjustment })
    }

    func testMenuItemIsInClipMenuWithoutShortcut() {
        var s = MenuState(); s.hasDocument = true
        let item = AppMenuSpec.clipAdd(s).first { $0.command == .addAdjustment }
        XCTAssertEqual(item?.title, "調整レイヤーを追加")
        XCTAssertNil(item?.shortcut)
        XCTAssertEqual(item?.enabled, true)
    }
}
