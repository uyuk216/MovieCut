import XCTest
import MovieCutCore
@testable import MovieCut

/// 他のクリップの値の表示(候補 30)のモデル操作。Undo は 1 回、変わらない編集は登録しない。
@MainActor
final class ValueRefAppTests: XCTestCase {
    private func undoSteps(_ m: ProjectModel, keep id: String) -> Int { let u = m.effectiveUndoManager; var n = 0; while u.canUndo { u.undo(); n += 1 }; for _ in 0..<n { u.redo() }; m.selectedClipId = id; return n }

    func testSetEditRemoveWithOneUndoEach() throws {
        let m = ProjectModel(project: .new())
        _ = m.addTextClip()
        let tid = try XCTUnwrap(m.selectedClipId)
        var img = Clip(); img.id = "img"; img.type = .image; img.src = "/nonexistent/a.png"; img.start = 0; img.duration = 3
        m.project.tracks[0].clips = [img]
        m.selectedClipId = tid
        XCTAssertEqual(m.valueRefCandidates(for: tid).map(\.id), ["img"])
        let base = undoSteps(m, keep: tid)
        m.setValueRef(ValueRef(clipId: "img"), name: "テスト", clipId: tid)
        XCTAssertEqual(m.clip(tid)?.valueRef?.clipId, "img")
        XCTAssertEqual(undoSteps(m, keep: tid), base + 1)
        m.setValueRef(ValueRef(clipId: "img"), name: "テスト", clipId: tid)
        m.editValueRef({ $0.param = "opacity" }, name: "テスト", clipId: tid)
        XCTAssertEqual(undoSteps(m, keep: tid), base + 1, "同じ値は履歴に載せない")
        m.editValueRef({ $0.param = "scale" }, name: "テスト", clipId: tid)
        XCTAssertEqual(m.clip(tid)?.valueRef?.param, "scale")
        XCTAssertEqual(undoSteps(m, keep: tid), base + 2)
        m.setValueRef(nil, name: "テスト", clipId: tid)
        XCTAssertNil(m.clip(tid)?.valueRef)
        XCTAssertEqual(undoSteps(m, keep: tid), base + 3)
    }
}
