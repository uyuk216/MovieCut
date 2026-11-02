import XCTest
import MovieCutCore
@testable import MovieCut

/// クリップの注記(インスペクタの「注記」欄・注記一覧)の App 側の決まり: 1 回の Undo・変わらない編集は積まない・空で消す。
@MainActor
final class NoteAppTests: XCTestCase {
    private func model() -> ProjectModel {
        let m = ProjectModel(project: .new())
        var c = Clip(); c.id = "t"; c.type = .text; c.text = "本文"; c.start = 1; c.duration = 2
        var p = m.project
        p.tracks[0].clips = [c]
        m.project = p
        return m
    }

    func testSetNoteCleansAndIsOneUndoStep() {
        let m = model()
        m.setClipNote("  メモ\n二行目  ", clipId: "t")
        XCTAssertEqual(m.clip("t")?.note, "メモ 二行目")
        XCTAssertTrue(m.effectiveUndoManager.canUndo)
        m.effectiveUndoManager.undo()
        XCTAssertNil(m.clip("t")?.note, "1 回の Undo で注記が消える")
    }

    func testSameNoteRegistersNothing() {
        let m = model()
        m.setClipNote("同じ", clipId: "t")
        m.effectiveUndoManager.removeAllActions()
        m.setClipNote("同じ", clipId: "t")
        XCTAssertFalse(m.effectiveUndoManager.canUndo, "変わらない注記は Undo に積まない")
    }

    func testBlankNoteRemovesTheField() {
        let m = model()
        m.setClipNote("あ", clipId: "t")
        m.setClipNote("   \n ", clipId: "t")
        XCTAssertNil(m.clip("t")?.note, "空白だけなら消す(ファイルにも書かない)")
    }

    func testNoteListingFollowsTheModel() {
        let m = model()
        XCTAssertTrue(NoteListing.entries(in: m.project).isEmpty)
        m.setClipNote("書いた", clipId: "t")
        XCTAssertEqual(NoteListing.entries(in: m.project).map(\.note), ["書いた"])
    }
}
