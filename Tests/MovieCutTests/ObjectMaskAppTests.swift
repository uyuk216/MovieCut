import XCTest
import MovieCutCore
@testable import MovieCut

/// オブジェクトマスク(モデル): 付け外し・項目変更は 1 回の Undo、羽根のドラッグは
/// 開始時点から計算し直す、作成できるクリップの判定、矩形指定の下書きの整え。
@MainActor
final class ObjectMaskAppTests: XCTestCase {

    private func video(_ id: String) -> Clip {
        var c = Clip(); c.id = id; c.type = .video; c.start = 0; c.duration = 2; c.src = "/tmp/none.mp4"
        return c
    }

    private func mask() -> ObjectMask {
        ObjectMask(sourceClipId: "v", seedRect: TrackRect(x: 0.25, y: 0.25, w: 0.5, h: 0.5),
                   samples: [ObjectMaskSample(t: 0, rect: TrackRect(x: 0.25, y: 0.25, w: 0.5, h: 0.5)),
                             ObjectMaskSample(t: 1, rect: TrackRect(x: 0.3, y: 0.25, w: 0.5, h: 0.5))])
    }

    private func makeModel(_ clips: [Clip]) -> ProjectModel {
        var p = Project.new()
        p.tracks[0].clips = clips
        let m = ProjectModel(project: p)
        m.notices = OneTimeNotices()
        return m
    }

    func testSetClearAndFieldAreOneUndoStepEach() {
        let m = makeModel([video("v")])
        m.selectedClipId = "v"
        m.setObjectMask(mask(), clipId: "v")
        XCTAssertEqual(m.selectedClip?.objectMask, mask())
        m.setObjectMaskField(clipId: "v") { $0.invert = true }
        XCTAssertEqual(m.selectedClip?.objectMask?.invert, true)
        let u = m.effectiveUndoManager
        u.undo()
        XCTAssertEqual(m.selectedClip?.objectMask?.invert, false, "反転の変更は 1 回で戻る")
        u.undo()
        XCTAssertNil(m.selectedClip?.objectMask, "付けた操作も 1 回で戻る")
        XCTAssertFalse(u.canUndo, "Undo は 2 回ぶんだけ")

        m.setObjectMask(mask(), clipId: "v")
        m.setObjectMask(nil, clipId: "v")
        XCTAssertNil(m.selectedClip?.objectMask, "削除は nil に戻す")
    }

    func testLiveFeatherDragRecomputesFromBase() {
        let m = makeModel([video("v")])
        m.selectedClipId = "v"
        m.setObjectMask(mask(), clipId: "v")
        m.beginGesture()
        m.liveObjectMaskField(clipId: "v") { $0.feather = 0.7 }
        m.liveObjectMaskField(clipId: "v") { $0.feather = 0.2 }
        m.commitGesture(ProjectModel.objectMaskUndoName)
        XCTAssertEqual(m.selectedClip?.objectMask?.feather ?? -1, 0.2, accuracy: 1e-9)
        // マスクが無いクリップでは何もしない
        m.setObjectMask(nil, clipId: "v")
        m.beginGesture()
        m.liveObjectMaskField(clipId: "v") { $0.feather = 0.9 }
        m.commitGesture(ProjectModel.objectMaskUndoName)
        XCTAssertNil(m.selectedClip?.objectMask)
    }

    func testCanCreateOnlyForOwnVideoOrImage() {
        let m = makeModel([video("v")])
        XCTAssertTrue(m.canCreateObjectMask(video("v")))
        var img = Clip(); img.type = .image; img.src = "/tmp/x.png"
        XCTAssertTrue(m.canCreateObjectMask(img))
        var noSrc = Clip(); noSrc.type = .video
        XCTAssertFalse(m.canCreateObjectMask(noSrc), "素材が無ければ作れない")
        var text = Clip(); text.type = .text; text.src = "/tmp/x.png"
        XCTAssertFalse(m.canCreateObjectMask(text), "文字クリップは対象外(輪郭の種が無い)")
    }

    func testSeedRectDraftIsNormalized() {
        let m = makeModel([video("v")])
        m.setObjectMaskSeedRectField { $0.x = 5; $0.w = 0 }
        XCTAssertEqual(m.objectMaskSeedRect.x, 2, "位置は TrackRect の整え(画面の少し外まで)に丸める")
        XCTAssertEqual(m.objectMaskSeedRect.w, 0.001)
    }

    func testPickingArmAndCancel() {
        let m = makeModel([video("v")])
        m.armObjectMaskPicking(clipId: "v")
        XCTAssertEqual(m.objectMaskPickingClipId, "v")
        m.cancelObjectMaskPicking()
        XCTAssertNil(m.objectMaskPickingClipId)
    }
}
