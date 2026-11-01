import XCTest
import MovieCutCore
@testable import MovieCut

/// 1 コマ移動と選択クリップへのズーム: 1 操作 = 1 Undo、動かせないときは Undo に載せない、ショートカットなし。
@MainActor
final class TimelineNudgeAppTests: XCTestCase {
    private func makeModel() -> ProjectModel {
        var p = Project.new()
        var a = Clip(); a.id = "a"; a.type = .image; a.start = 1; a.duration = 2; a.src = "/tmp/none.png"
        p.tracks[0].clips = [a]
        let m = ProjectModel(project: p)
        m.notices = OneTimeNotices()
        return m
    }

    func testNudgeIsOneUndoStepAndUndoRestores() throws {
        let m = makeModel()
        m.selectedClipIDs = ["a"]; m.selectedClipId = "a"
        XCTAssertTrue(m.nudgeSelectedClips(frames: 1))
        XCTAssertEqual(m.effectiveUndoManager.undoActionName, "1 コマ後ろへ動かす")
        XCTAssertEqual(try XCTUnwrap(m.project.allClips.first?.start), 1 + 1.0 / m.project.fps, accuracy: 1e-9)
        m.effectiveUndoManager.undo()
        XCTAssertEqual(m.project.allClips.first?.start, 1)
    }

    func testNudgeWithNoEffectDoesNotRegisterUndo() {
        let m = makeModel()
        m.selectedClipIDs = ["a"]; m.selectedClipId = "a"
        m.project.tracks[0].clips[0].start = 0
        XCTAssertFalse(m.nudgeSelectedClips(frames: -1))
        XCTAssertFalse(m.effectiveUndoManager.canUndo)
    }

    func testZoomPpsFitsSelectionInNinetyPercentOfWidth() {
        XCTAssertEqual(TimelineLayout.zoomPps(visibleWidth: 900, span: 9), 90, accuracy: 1e-9)
        XCTAssertEqual(TimelineLayout.zoomPps(visibleWidth: 900, span: 0.0001), TimelineLayout.maxPps)  // 範囲内に収める
        XCTAssertEqual(TimelineLayout.zoomPps(visibleWidth: 0, span: 5), TimelineLayout.defaultPps)
    }

    func testNudgeMenuItemsHaveNoShortcutAndNeedSelection() {
        var s = MenuState(); s.hasDocument = true
        let items = AppMenuSpec.clipEdit(s).filter { $0.title.hasSuffix("動かす") }
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items.allSatisfy { $0.shortcut == nil && !$0.enabled }, "選択が無いときは押せない")
    }
}
