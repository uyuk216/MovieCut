import XCTest
import MovieCutCore
@testable import MovieCut

/// クリップ ▸ 配置 ▸ 右上などに小さく(1 回の Undo。変わらないときは登録しない。音声には使わない)。
@MainActor
final class PlacementAppTests: XCTestCase {
    private func undoSteps(_ m: ProjectModel, keep id: String) -> Int { let u = m.effectiveUndoManager; var n = 0; while u.canUndo { u.undo(); n += 1 }; for _ in 0..<n { u.redo() }; m.selectedClipId = id; return n }

    func testSetPipCornerIsOneUndoAndNoOpRegistersNothing() throws {
        let m = ProjectModel(project: .new())
        _ = m.addTextClip()
        let id = try XCTUnwrap(m.selectedClipId)
        let base = undoSteps(m, keep: id)
        XCTAssertTrue(m.setPipCorner(.topRight))
        XCTAssertEqual(m.clip(id)?.scale ?? -1, 0.3, accuracy: 1e-9)
        XCTAssertEqual(undoSteps(m, keep: id), base + 1)
        let after = undoSteps(m, keep: id)
        XCTAssertFalse(m.setPipCorner(.topRight))
        XCTAssertEqual(undoSteps(m, keep: id), after, "同じ配置は履歴に載せない")
    }

    func testMenuItemsAreEnabledOnlyForVisualClips() throws {
        var s = MenuState()
        s.hasDocument = true
        s.canPip = true
        XCTAssertEqual(AppMenuSpec.pipItems(s).map(\.title), ["右上に小さく", "右下に小さく", "左上に小さく", "左下に小さく"])
        XCTAssertTrue(AppMenuSpec.pipItems(s).allSatisfy { $0.enabled && $0.shortcut == nil })
        s.canPip = false
        XCTAssertFalse(AppMenuSpec.pipItems(s).contains { $0.enabled })
    }
}
