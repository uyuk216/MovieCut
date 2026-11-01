import XCTest
import MovieCutCore
@testable import MovieCut

/// キャラ欄の「字幕の文字色」(設定・既定に戻す)。1 回の Undo。同じ値は履歴に載せない。
@MainActor
final class SpeakerColorAppTests: XCTestCase {
    private func undoSteps(_ m: ProjectModel) -> Int { let u = m.effectiveUndoManager; var n = 0; while u.canUndo { u.undo(); n += 1 }; for _ in 0..<n { u.redo() }; return n }

    func testSetAndResetAreOneUndoEachAndNoOpRegistersNothing() throws {
        var p = Project.new()
        p.characters = Character.defaults()
        let m = ProjectModel(project: p)
        let id = try XCTUnwrap(p.characters.first?.id)
        let base = undoSteps(m)
        m.setCharacterProperty({ $0.subtitleColor = "#ff0000" }, name: "話し手の字幕の色の変更", charId: id)
        XCTAssertEqual(m.project.characters.first?.subtitleColor, "#ff0000")
        XCTAssertEqual(undoSteps(m), base + 1)
        let mid = undoSteps(m)
        m.setCharacterProperty({ $0.subtitleColor = "#ff0000" }, name: "話し手の字幕の色の変更", charId: id)
        XCTAssertEqual(undoSteps(m), mid, "同じ色は履歴に載せない")
        m.setCharacterProperty({ $0.subtitleColor = nil }, name: "話し手の字幕の色を外す", charId: id)
        XCTAssertNil(m.project.characters.first?.subtitleColor)
    }
}
