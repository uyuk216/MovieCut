import XCTest
import MovieCutCore
@testable import MovieCut

/// 立ち絵素材・立ち絵クリップ・字幕の文の編集: 1 回 = Undo 1 回、何も変わらない編集は履歴に載せない。
@MainActor
final class TachieAppTests: XCTestCase {
    private func undoSteps(_ m: ProjectModel) -> Int { let u = m.effectiveUndoManager; var n = 0; while u.canUndo { u.undo(); n += 1 }; for _ in 0..<n { u.redo() }; return n }

    private func model() -> (ProjectModel, String) {
        let m = ProjectModel(project: Project.new())
        var t = Tachie(name: "霊夢"); t.id = "t1"; t.imgClosed = "/a.png"
        t.rig = CharacterRig(slots: [RigSlot(name: "体", parts: ["/b.png"], active: 0)])
        _ = m.addTachie(t)
        return (m, "t1")
    }

    func testAddRenameRemoveAreOneUndoStepEach() {
        let (m, id) = model()
        XCTAssertEqual(m.project.tachies.count, 1); XCTAssertEqual(undoSteps(m), 1)
        m.renameTachie(id: id, to: "霊夢"); XCTAssertEqual(undoSteps(m), 1, "同じ名前は履歴に載せない")
        m.renameTachie(id: id, to: "霊夢2"); XCTAssertEqual(undoSteps(m), 2)
        var dup = Tachie(name: "x"); dup.id = id
        XCTAssertNil(m.addTachie(dup)); XCTAssertEqual(undoSteps(m), 2)
        let cid = m.addTachieClip(tachieId: id, start: 1, duration: 2)
        XCTAssertNotNil(cid); XCTAssertEqual(m.selectedClipId, cid); XCTAssertEqual(undoSteps(m), 3)
        m.removeTachie(id: id)
        XCTAssertTrue(m.project.tachies.isEmpty); XCTAssertTrue(m.project.allClips.filter { $0.type == .tachie }.isEmpty)
        XCTAssertEqual(undoSteps(m), 4)
        m.removeTachie(id: id); XCTAssertEqual(undoSteps(m), 4, "無い素材の削除は何もしない")
        m.effectiveUndoManager.undo()
        XCTAssertEqual(m.project.tachies.count, 1); XCTAssertEqual(m.project.allClips.filter { $0.type == .tachie }.count, 1, "Undo で素材とクリップが戻る")
    }

    func testClipDriveOffsetsAndSubtitleEdits() {
        let (m, id) = model()
        XCTAssertNil(m.addTachieClip(tachieId: "none")); XCTAssertNil(m.addTachieClip(tachieId: id, duration: 0))
        let cid = m.addTachieClip(tachieId: id, start: 0, duration: 4, drive: .character("ch"))!
        XCTAssertEqual(m.project.allClips.first { $0.id == cid }?.mouthDrive, .character("ch"))
        assertNoLayerOverlaps(m.project)
        let c2 = m.addTachieClip(tachieId: id, start: 1, duration: 2)!   // 重なる → 別のレイヤー
        assertNoLayerOverlaps(m.project)
        XCTAssertNotEqual(m.project.tracks.firstIndex { $0.clips.contains { $0.id == cid } }, m.project.tracks.firstIndex { $0.clips.contains { $0.id == c2 } })
        var steps = undoSteps(m)
        m.setTachieMouthDrive(clipId: cid, drive: .character("ch")); XCTAssertEqual(undoSteps(m), steps, "同じ連動は載せない")
        m.setTachieMouthDrive(clipId: cid, drive: .none); steps += 1; XCTAssertEqual(undoSteps(m), steps)
        m.setTachieMouthDrive(clipId: cid, drive: .all); steps += 1; XCTAssertEqual(undoSteps(m), steps)
        XCTAssertNil(m.project.allClips.first { $0.id == cid }?.mouthDrive)

        m.setTachiePartOffset(tachieId: id, path: "/b.png", offset: PartOffset()); XCTAssertEqual(undoSteps(m), steps, "ゼロのままは載せない")
        m.setTachiePartOffset(tachieId: id, path: "/b.png", offset: PartOffset(dx: 3, dy: 4)); steps += 1; XCTAssertEqual(undoSteps(m), steps)
        m.effectiveUndoManager.undo()
        XCTAssertNil(m.project.tachies[0].rig?.partOffsets)

        var v = Clip(); v.id = "v"; v.type = .voice; v.text = "よみ"; v.start = 10; v.duration = 1
        m.edit("声") { $0.tracks[0].clips.append(v) }
        steps = undoSteps(m)
        m.setVoiceSubtitleText(clipId: "v", text: nil); XCTAssertEqual(undoSteps(m), steps)
        m.setVoiceSubtitleText(clipId: "v", text: ""); steps += 1; XCTAssertEqual(undoSteps(m), steps)
        XCTAssertEqual(m.project.allClips.first { $0.id == "v" }?.subtitleText, "")
        m.setVoiceSubtitleText(clipId: "v", text: nil); steps += 1; XCTAssertEqual(undoSteps(m), steps)
        XCTAssertNil(m.project.allClips.first { $0.id == "v" }?.subtitleText)
    }

    func testLockedLayerRefusesEdits() {
        let (m, id) = model()
        let cid = m.addTachieClip(tachieId: id, start: 0, duration: 3)!
        let ti = m.project.tracks.firstIndex { $0.clips.contains { $0.id == cid } }!
        m.edit("ロック") { $0.tracks[ti].locked = true }
        let before = undoSteps(m)
        m.setTachieMouthDrive(clipId: cid, drive: .none)
        XCTAssertEqual(undoSteps(m), before); XCTAssertNil(m.project.allClips.first { $0.id == cid }?.mouthDrive)
        m.removeTachie(id: id)
        XCTAssertEqual(m.project.tachies.count, 1, "ロックされたクリップを含む削除は断る")
    }
}
