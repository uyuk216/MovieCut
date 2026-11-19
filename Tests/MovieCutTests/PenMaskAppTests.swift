import XCTest
import MovieCutCore
@testable import MovieCut

/// ペンマスク(モデル): 形の切り替えで既定の点が用意される、点の追加・削除・ハンドル初期化が各 1 回の Undo、
/// ドラッグ(live)で元へ戻せる。形のマスクの作法と同じ。
@MainActor
final class PenMaskAppTests: XCTestCase {

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

    private func penModel() -> ProjectModel {
        let m = makeModel([image("i")])
        m.selectedClipId = "i"
        m.setClipMask(ClipMask(), clipId: "i")
        m.setMaskShape("pen", clipId: "i")
        return m
    }

    func testSwitchingToPenSeedsDefaultPointsAsOneUndoStep() {
        let m = penModel()
        XCTAssertEqual(m.selectedClip?.mask?.shape, "pen")
        XCTAssertEqual(m.selectedClip?.mask?.points, ClipMask.defaultPenPoints, "ペンへ切り替えると既定の菱形が入る")
        let u = m.effectiveUndoManager
        u.undo()
        XCTAssertEqual(m.selectedClip?.mask, ClipMask(), "切り替えは 1 回で戻る(点も一緒に戻る)")
        u.undo()
        XCTAssertNil(m.selectedClip?.mask)
        XCTAssertFalse(u.canUndo)
    }

    func testAddRemoveAndResetAreOneUndoStepEach() {
        let m = penModel()
        m.addPenPoint(clipId: "i")
        XCTAssertEqual(m.selectedClip?.mask?.points.count, 5, "閉じる辺の中点に点が増える")
        // 追加した点は、最後の点(0.25,0.5)と最初の点(0.5,0.25)の中点
        let added = m.selectedClip?.mask?.points.last
        XCTAssertEqual(added?.x ?? -1, 0.375, accuracy: 1e-9)
        XCTAssertEqual(added?.y ?? -1, 0.375, accuracy: 1e-9)
        m.removePenPoint(index: 4, clipId: "i")
        XCTAssertEqual(m.selectedClip?.mask?.points, ClipMask.defaultPenPoints)
        // ハンドルを付けてから初期化する
        m.setMaskField(clipId: "i") { $0.points[0].outX = 0.9 }
        XCTAssertEqual(m.selectedClip?.mask?.points[0].outX, 0.9)
        m.resetPenHandles(index: 0, clipId: "i")
        XCTAssertTrue(m.selectedClip?.mask?.points[0].isCorner ?? false, "ハンドルがアンカーへ戻る")
        let u = m.effectiveUndoManager
        u.undo()
        XCTAssertEqual(m.selectedClip?.mask?.points[0].outX, 0.9, "初期化は 1 回で戻る")
    }

    func testRemoveKeepsAtLeastThreePoints() {
        let m = penModel()
        m.removePenPoint(index: 0, clipId: "i")
        XCTAssertEqual(m.selectedClip?.mask?.points.count, 3)
        let before = m.selectedClip?.mask
        m.removePenPoint(index: 0, clipId: "i")
        XCTAssertEqual(m.selectedClip?.mask, before, "3 点では削除しない")
        m.removePenPoint(index: 99, clipId: "i")
        XCTAssertEqual(m.selectedClip?.mask, before, "範囲外の削除もしない")
    }

    func testLiveDragMovesPointAndReturnsToBase() {
        let m = penModel()
        m.beginGesture()
        m.liveMaskField(clipId: "i") { mask in
            mask.points[1] = MaskPoint(x: 0.9, y: 0.5, inX: 0.9, inY: 0.2, outX: 0.9, outY: 0.8)
        }
        m.commitGesture(ProjectModel.maskUndoName)
        XCTAssertEqual(m.selectedClip?.mask?.points[1].x, 0.9)
        XCTAssertEqual(m.selectedClip?.mask?.points[1].inY, 0.2)
        m.beginGesture()
        m.liveMaskField(clipId: "i") { $0.points[1] = ClipMask.defaultPenPoints[1] }
        m.commitGesture(ProjectModel.maskUndoName)
        XCTAssertEqual(m.selectedClip?.mask?.points, ClipMask.defaultPenPoints, "元へ戻すと既定の点列と一致する")
    }

    func testPenOperationsDoNothingForRectMask() {
        let m = makeModel([image("i")])
        m.selectedClipId = "i"
        m.setClipMask(ClipMask(), clipId: "i")
        m.addPenPoint(clipId: "i")
        m.removePenPoint(index: 0, clipId: "i")
        XCTAssertEqual(m.selectedClip?.mask, ClipMask(), "矩形のままでは点の操作は効かない")
    }
}
