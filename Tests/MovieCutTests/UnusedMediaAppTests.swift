import XCTest
import MovieCutCore
@testable import MovieCut

@MainActor
final class UnusedMediaAppTests: XCTestCase {
    private func model() -> ProjectModel {
        let m = ProjectModel(project: .new())
        var p = m.project
        p.mediaPool = ["/m/a.png", "/m/b.png"]
        m.project = p
        return m
    }

    func testBulkRemoveIsOneUndoAndRestores() {
        let m = model()
        m.effectiveUndoManager.removeAllActions()
        m.removeUnusedMedia(nil)
        XCTAssertTrue(UnusedMedia.find(in: m.project).isEmpty)
        XCTAssertTrue(m.project.mediaPool.isEmpty)
        m.effectiveUndoManager.undo()
        XCTAssertEqual(UnusedMedia.find(in: m.project).map(\.path), ["/m/a.png", "/m/b.png"])
    }

    func testSingleRemoveAndNoOpNotRegistered() {
        let m = model()
        m.effectiveUndoManager.removeAllActions()
        m.removeUnusedMedia(["/m/a.png"])
        XCTAssertEqual(m.project.mediaPool, ["/m/b.png"])
        m.effectiveUndoManager.undo()
        XCTAssertEqual(m.project.mediaPool, ["/m/a.png", "/m/b.png"])
        m.effectiveUndoManager.removeAllActions()
        m.removeUnusedMedia(["/nope"])
        XCTAssertFalse(m.effectiveUndoManager.canUndo)
    }

    func testMenuReasonWhenNoUnusedMedia() {
        var s = MenuState()
        s.hasDocument = true
        s.hasUnusedMedia = false
        let spec = AppMenuSpec.unusedMediaItem(s)
        XCTAssertFalse(spec.enabled)
        XCTAssertNil(spec.shortcut)
        XCTAssertEqual(AppMenuSpec.disabledReason(for: spec, state: s), "未使用の素材はありません")
    }
}

@MainActor
final class UnusedMediaAdoptAppTests: XCTestCase {
    func testDeletingClipFromOldProjectMakesItsMediaUnusedAndUndoRestores() {
        var c = Clip(); c.id = "a"; c.type = .image; c.src = "/m/old.png"; c.duration = 2
        var p = Project.new(); p.tracks[0].clips = [c]
        let m = ProjectModel(project: p)
        m.selectedClipId = "a"
        XCTAssertTrue(m.project.mediaPool.isEmpty)
        XCTAssertTrue(m.deleteSelected())
        XCTAssertEqual(UnusedMedia.find(in: m.project).map(\.path), ["/m/old.png"])
        m.effectiveUndoManager.undo()
        XCTAssertTrue(m.project.mediaPool.isEmpty)
        XCTAssertNotNil(m.clip("a"))
    }
}
