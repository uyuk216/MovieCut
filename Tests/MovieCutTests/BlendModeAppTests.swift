import XCTest
import MovieCutCore
@testable import MovieCut

/// ブレンドモードの画面配線: プロパティ欄の「合成方法」が使うモデルの書き換え(setClipProperty)が、
/// 1 回の Undo で効くこと・同じ値では何も登録しないこと。
@MainActor
final class BlendModeAppTests: XCTestCase {
    private func makeModel() -> (ProjectModel, String) {
        let m = ProjectModel(project: .new())
        var c = Clip(); c.id = "i"; c.type = .image; c.start = 0; c.duration = 3
        m.project.tracks[0].clips = [c]
        m.selectedClipId = "i"
        return (m, "i")
    }

    func testSetAndClearBlendModeWithUndo() {
        let (m, id) = makeModel()
        XCTAssertNil(m.clip(id)?.blendMode)
        m.setClipProperty(\.blendMode, to: ClipBlendMode.multiply, name: "合成方法の変更", clipId: id)
        XCTAssertEqual(m.clip(id)?.blendMode, .multiply)
        // 同じ値では Undo に積まない
        m.setClipProperty(\.blendMode, to: ClipBlendMode.multiply, name: "合成方法の変更", clipId: id)
        // 通常に戻す(nil)
        m.setClipProperty(\.blendMode, to: nil, name: "合成方法の変更", clipId: id)
        XCTAssertNil(m.clip(id)?.blendMode)
        var steps = 0
        while m.effectiveUndoManager.canUndo { m.effectiveUndoManager.undo(); steps += 1 }
        XCTAssertEqual(steps, 2, "設定と解除の 2 回だけ")
        XCTAssertNil(m.clip(id)?.blendMode)
    }
}
