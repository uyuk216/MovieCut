import XCTest
import MovieCutCore
@testable import MovieCut

/// ビートにマーカーを打つ: 1 回の Undo、足すものが無ければ何もしない、ショートカットなしのメニュー項目。
@MainActor
final class BeatAppTests: XCTestCase {
    private func makeModel() -> ProjectModel {
        var p = Project.new()
        var i = Clip(); i.id = "i"; i.type = .image; i.start = 0; i.duration = 4; i.src = "/tmp/none.png"
        p.tracks[0].clips = [i]
        let m = ProjectModel(project: p)
        m.notices = OneTimeNotices()
        return m
    }

    func testBeatMarkersAreOneUndoStepAndNoOpWhenNone() {
        let m = makeModel()
        XCTAssertFalse(m.applyBeatMarkers([], bpm: 120), "足すものが無いときは何もしない")
        XCTAssertTrue(m.project.markers.isEmpty)
        XCTAssertFalse(m.effectiveUndoManager.canUndo, "Undo に載らない")
        XCTAssertTrue(m.applyBeatMarkers([0.5, 1.0, 1.5], bpm: 120))
        XCTAssertEqual(m.project.markers.map(\.time), [0.5, 1.0, 1.5])
        XCTAssertEqual(m.effectiveUndoManager.undoActionName, "ビートにマーカー")
        m.effectiveUndoManager.undo()
        XCTAssertTrue(m.project.markers.isEmpty, "1 回の Undo で全部戻る")
    }

    func testMenuItemHasNoShortcutAndNeedsAnAudibleClip() {
        var s = MenuState(); s.hasDocument = true
        let item = AppMenuSpec.beatMarkersItem(s)
        XCTAssertEqual(item.title, "ビートにマーカーを打つ")
        XCTAssertNil(item.shortcut)
        XCTAssertFalse(item.enabled, "音のクリップを選んでいないときは押せない")
        s.canBeatMarkers = true
        XCTAssertTrue(AppMenuSpec.beatMarkersItem(s).enabled)
    }
}
