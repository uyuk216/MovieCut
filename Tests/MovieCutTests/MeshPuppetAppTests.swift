import XCTest
import MovieCutCore
@testable import MovieCut

/// メッシュ/パペット変形(モデル): 1 回の Undo・ドラッグで元に戻る・外すと nil。
@MainActor
final class MeshPuppetAppTests: XCTestCase {

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

    func testMeshOnOffAndGridAreOneUndoStepEach() {
        let m = makeModel([image("i")])
        m.selectedClipId = "i"
        m.ensureMeshWarp(clipId: "i")
        XCTAssertNotNil(m.selectedClip?.meshWarp)
        XCTAssertFalse(m.selectedClip?.hasActiveWarp ?? true, "全点が元の位置では変形なし")
        m.setMeshGrid(cols: 5, rows: 5, clipId: "i")
        XCTAssertEqual(m.selectedClip?.meshWarp?.cols, 5)
        let u = m.effectiveUndoManager
        u.undo()
        XCTAssertEqual(m.selectedClip?.meshWarp?.cols, 3, "格子の変更は 1 回で戻る")
        m.clearMeshWarp(clipId: "i")
        XCTAssertNil(m.selectedClip?.meshWarp)
        u.undo()
        XCTAssertNotNil(m.selectedClip?.meshWarp, "外す操作も 1 回で戻る")
    }

    func testLiveMeshDragIsOneUndoAndReturnsToBase() {
        let m = makeModel([image("i")])
        m.selectedClipId = "i"
        m.ensureMeshWarp(clipId: "i")
        m.beginGesture()
        m.liveMeshPoint(clipId: "i", index: 4, x: 0.9, y: 0.5)
        m.liveMeshPoint(clipId: "i", index: 4, x: 0.7, y: 0.5)
        m.commitGesture(ProjectModel.warpUndoName)
        XCTAssertEqual(m.selectedClip?.meshWarp?.points[4].x ?? -1, 0.7, accuracy: 1e-9)
        XCTAssertTrue(m.selectedClip?.hasActiveWarp ?? false)
        let u = m.effectiveUndoManager
        u.undo()
        XCTAssertEqual(m.selectedClip?.meshWarp?.points[4].x ?? -1, 0.5, accuracy: 1e-9, "ドラッグ全体が 1 回の Undo で戻る")
        XCTAssertFalse(m.selectedClip?.hasActiveWarp ?? true)
    }

    func testPuppetPinFlowThroughModel() {
        let m = makeModel([image("i")])
        m.selectedClipId = "i"
        m.ensurePuppetWarp(clipId: "i")
        m.addPuppetPin(fixed: false, clipId: "i")
        XCTAssertEqual(m.selectedClip?.puppetWarp?.pins.count, 1)
        m.beginGesture()
        m.livePuppetPin(clipId: "i", index: 0, x: 0.5, y: 0.9)
        m.commitGesture(ProjectModel.warpUndoName)
        XCTAssertEqual(m.selectedClip?.puppetWarp?.pins[0].y ?? -1, 0.9, accuracy: 1e-9)
        XCTAssertTrue(m.selectedClip?.hasActiveWarp ?? false)
        m.setPuppetPinFixed(index: 0, true, clipId: "i")
        XCTAssertFalse(m.selectedClip?.hasActiveWarp ?? true, "固定にすると変位は消える")
        m.removePuppetPin(index: 0, clipId: "i")
        XCTAssertEqual(m.selectedClip?.puppetWarp?.pins.count, 0)
        m.clearPuppetWarp(clipId: "i")
        XCTAssertNil(m.selectedClip?.puppetWarp)
    }
}
