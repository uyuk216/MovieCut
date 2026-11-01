import XCTest
import MovieCutCore
@testable import MovieCut

/// スタンプ(クリップ ▸ スタンプを追加 ▸ 絵文字): 1 操作 = 1 Undo、一番上のレイヤーに置く、ショートカットなし。
@MainActor
final class StampAppTests: XCTestCase {
    private func makeModel() -> ProjectModel {
        var p = Project.new()
        var i = Clip(); i.id = "i"; i.type = .image; i.start = 0; i.duration = 4; i.src = "/tmp/none.png"
        p.tracks[0].clips = [i]
        let m = ProjectModel(project: p)
        m.notices = OneTimeNotices()
        return m
    }

    func testAddStampIsOneUndoStepOnTopLayerAndSelected() {
        let m = makeModel()
        m.currentTime = 2
        AppMenu.perform(.addStamp("🎉"), model: m)
        let top = m.project.tracks[m.project.tracks.count - 1].clips.last
        XCTAssertEqual(top?.type, .text)
        XCTAssertEqual(top?.text, "🎉")
        XCTAssertEqual(top?.start, 2)
        XCTAssertEqual(m.selectedClipId, top?.id)
        XCTAssertEqual(m.effectiveUndoManager.undoActionName, "スタンプの追加")
        m.effectiveUndoManager.undo()
        XCTAssertFalse(m.project.tracks.flatMap(\.clips).contains { $0.text == "🎉" })
    }

    func testStampItemsHaveNoShortcutAndCoverCatalog() {
        var s = MenuState(); s.hasDocument = true
        let items = AppMenuSpec.stampItems(s)
        XCTAssertEqual(items.count, 24)
        XCTAssertTrue(items.allSatisfy { $0.shortcut == nil && $0.enabled })
        var locked = MenuState(); locked.hasDocument = true; locked.isLocked = true
        XCTAssertTrue(AppMenuSpec.stampItems(locked).allSatisfy { !$0.enabled })
    }
}
