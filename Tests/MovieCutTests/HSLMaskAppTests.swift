import XCTest
import MovieCutCore
@testable import MovieCut

/// HSL マスク(モデル): 1 回の Undo・ドラッグで元に戻る・オフは nil。形のマスクの作法と同じ。
@MainActor
final class HSLMaskAppTests: XCTestCase {

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
        m.setHSLMask(HSLMask(), clipId: "i")
        XCTAssertEqual(m.selectedClip?.hslMask, HSLMask())
        m.setHSLMaskField(clipId: "i") { $0.invert = true }
        XCTAssertEqual(m.selectedClip?.hslMask?.invert, true)
        m.setHSLMaskField(clipId: "i") { $0.selection.hueCenter = 120 }
        XCTAssertEqual(m.selectedClip?.hslMask?.selection.hueCenter, 120)
        let u = m.effectiveUndoManager
        u.undo()
        XCTAssertEqual(m.selectedClip?.hslMask?.selection.hueCenter, 0, "選択の変更は 1 回で戻る")
        u.undo()
        XCTAssertEqual(m.selectedClip?.hslMask?.invert, false, "反転の変更も 1 回で戻る")
        u.undo()
        XCTAssertNil(m.selectedClip?.hslMask, "オンにした操作も 1 回で戻る")
        XCTAssertFalse(u.canUndo, "Undo は 3 回ぶんだけ")
    }

    func testLiveDragReturnsToBaseWhenMovedBack() {
        let m = makeModel([image("i")])
        m.selectedClipId = "i"
        m.setHSLMask(HSLMask(), clipId: "i")
        m.beginGesture()
        m.liveHSLMaskField(clipId: "i") { $0.selection.satMin = 0.7 }
        m.liveHSLMaskField(clipId: "i") { $0.selection.satMin = 0.2 }
        m.commitGesture(ProjectModel.hslMaskUndoName)
        XCTAssertEqual(m.selectedClip?.hslMask?.selection.satMin ?? -1, 0.2, accuracy: 1e-9)
        m.beginGesture()
        m.liveHSLMaskField(clipId: "i") { $0.selection.satMin = 0 }
        m.liveHSLMaskField(clipId: "i") { $0.selection.satMin = 0 }
        m.commitGesture(ProjectModel.hslMaskUndoName)
        XCTAssertEqual(m.selectedClip?.hslMask, HSLMask(), "既定値に戻すと既定のマスクと同じになる")
    }

    func testPreviewToggleIsOneUndoStep() {
        let m = makeModel([image("i")])
        m.selectedClipId = "i"
        m.setHSLMask(HSLMask(), clipId: "i")
        m.setHSLMaskField(clipId: "i") { $0.preview = .grayOutside }
        XCTAssertEqual(m.selectedClip?.hslMask?.preview, .grayOutside)
        m.effectiveUndoManager.undo()
        XCTAssertEqual(m.selectedClip?.hslMask?.preview, .off)
    }
}
