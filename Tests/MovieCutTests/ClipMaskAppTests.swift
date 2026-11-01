import XCTest
import MovieCutCore
@testable import MovieCut

/// 形のマスク(モデル): 1 回の Undo・ドラッグで元に戻る・オフは nil。
@MainActor
final class ClipMaskAppTests: XCTestCase {

    private func image(_ id: String) -> Clip {
        var c = Clip(); c.id = id; c.type = .image; c.start = 0; c.duration = 2; c.src = "/tmp/none.png"
        return c
    }

    private func makeModel(_ clips: [Clip]) -> ProjectModel {
        var p = Project.new()
        p.tracks[0].clips = clips
        let m = ProjectModel(project: p)
        m.notices = OneTimeNotices()
        return m
    }

    func testOnOffAndFieldChangesAreOneUndoStepEach() {
        let m = makeModel([image("i")])
        m.selectedClipId = "i"
        m.setClipMask(ClipMask(), clipId: "i")
        XCTAssertEqual(m.selectedClip?.mask, ClipMask())
        m.setMaskField(clipId: "i") { $0.shape = "ellipse" }
        XCTAssertEqual(m.selectedClip?.mask?.shape, "ellipse")
        let u = m.effectiveUndoManager
        u.undo()
        XCTAssertEqual(m.selectedClip?.mask, ClipMask(), "形の変更は 1 回で戻る")
        u.undo()
        XCTAssertNil(m.selectedClip?.mask, "オンにした操作も 1 回で戻る")
        XCTAssertFalse(u.canUndo, "Undo は 2 回ぶんだけ")
    }

    func testLiveDragReturnsToBaseWhenMovedBack() {
        let m = makeModel([image("i")])
        m.selectedClipId = "i"
        m.setClipMask(ClipMask(), clipId: "i")
        m.beginGesture()
        m.liveMaskField(clipId: "i") { $0.feather = 0.7 }
        m.liveMaskField(clipId: "i") { $0.feather = 0.2 }
        m.commitGesture(ProjectModel.maskUndoName)
        XCTAssertEqual(m.selectedClip?.mask?.feather ?? -1, 0.2, accuracy: 1e-9)
        m.beginGesture()
        m.liveMaskField(clipId: "i") { $0.feather = 0 }
        m.liveMaskField(clipId: "i") { $0.feather = 0 }
        m.commitGesture(ProjectModel.maskUndoName)
        XCTAssertEqual(m.selectedClip?.mask, ClipMask(), "羽根 0 に戻すと既定のマスクと同じになる")
    }
}
