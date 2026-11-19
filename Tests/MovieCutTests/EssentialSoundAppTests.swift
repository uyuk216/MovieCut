import XCTest
import MovieCutCore
@testable import MovieCut

/// エッセンシャルサウンド: モデルの操作(種別の変更・整音の適用がそれぞれ Undo 1 回、
/// 何も変わらない操作は履歴に載らない)とパネルの生成。
@MainActor
final class EssentialSoundAppTests: XCTestCase {
    private func clip(_ id: String, _ type: ClipType, start: Double, dur: Double) -> Clip {
        var c = Clip(); c.id = id; c.type = type; c.start = start; c.duration = dur
        if type == .audio || type == .voice || type == .video { c.src = "/tmp/none.wav" }
        return c
    }

    private func makeModel() -> ProjectModel {
        var p = Project.new()
        p.tracks[0].clips = [clip("m", .audio, start: 0, dur: 6), clip("k", .voice, start: 10, dur: 2)]
        p.tracks[1].clips = [clip("v", .video, start: 2, dur: 6), clip("i", .image, start: 0, dur: 4)]
        let m = ProjectModel(project: p)
        m.notices = OneTimeNotices()
        return m
    }

    private func undoSteps(_ m: ProjectModel) -> Int {
        let u = m.effectiveUndoManager
        var n = 0
        while u.canUndo { u.undo(); n += 1 }
        for _ in 0..<n { u.redo() }
        return n
    }

    func testSetCategoryIsOneUndoStepAndNoOpRegistersNothing() {
        let m = makeModel()
        let u = m.effectiveUndoManager
        XCTAssertTrue(m.setAudioCategory(clipId: "m", .dialogue))
        XCTAssertEqual(m.clip("m")?.audioCategory, .dialogue)
        XCTAssertEqual(u.undoActionName, ProjectModel.audioCategoryUndoName)
        XCTAssertEqual(undoSteps(m), 1)
        XCTAssertFalse(m.setAudioCategory(clipId: "m", .dialogue), "同じ種別は変化なし")
        XCTAssertEqual(undoSteps(m), 1)
        XCTAssertFalse(m.setAudioCategory(clipId: "i", .dialogue), "画像クリップは対象外")
        XCTAssertFalse(m.setAudioCategory(clipId: "nope", .dialogue))
        XCTAssertEqual(undoSteps(m), 1)
        u.undo()
        XCTAssertNil(m.clip("m")?.audioCategory, "Undo 1 回でタグが戻る")
        u.redo()
        XCTAssertEqual(m.clip("m")?.audioCategory, .dialogue)
    }

    func testApplyPresetIsOneUndoStep() {
        let m = makeModel()
        let u = m.effectiveUndoManager
        XCTAssertFalse(m.applyEssentialSound(clipId: "m"), "種別が無ければ適用できない")
        XCTAssertTrue(m.setAudioCategory(clipId: "m", .dialogue))
        XCTAssertTrue(m.applyEssentialSound(clipId: "m"))
        XCTAssertEqual(u.undoActionName, ProjectModel.essentialSoundUndoName)
        XCTAssertEqual(m.clip("m")?.treatAsVoice, true)
        XCTAssertEqual(m.clip("m")?.audioFx?.normalize?.targetDb, -16)
        XCTAssertEqual(undoSteps(m), 2, "種別の変更 1 回 + 整音 1 回")
        XCTAssertFalse(m.applyEssentialSound(clipId: "m"), "適用済みなら変化なし")
        XCTAssertEqual(undoSteps(m), 2)
        u.undo()
        XCTAssertNil(m.clip("m")?.audioFx, "Undo 1 回で整音が全部戻る")
        XCTAssertNil(m.clip("m")?.treatAsVoice)
        XCTAssertEqual(m.clip("m")?.audioCategory, .dialogue, "種別タグは残る")
        u.undo()
        XCTAssertNil(m.clip("m")?.audioCategory)
    }

    func testPanelBuildsForAudioClip() {
        let m = makeModel()
        let panel = EssentialSoundPanel(model: m, clipId: "m")
        XCTAssertNotNil(panel.body)
        let imagePanel = EssentialSoundPanel(model: m, clipId: "i")
        XCTAssertNotNil(imagePanel.body)
    }
}
