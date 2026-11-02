import XCTest
import MovieCutCore
@testable import MovieCut

/// コマの補間(なし / ブレンド / オプティカルフロー)の切り替え: 1 回の Undo・何も変わらなければ履歴に載せない・使えない場合は断る。
@MainActor
final class FrameInterpolationAppTests: XCTestCase {
    private func model() -> ProjectModel {
        var p = Project.new()
        var v = Clip(); v.id = "v"; v.type = .video; v.src = "/nonexistent/a.mov"; v.start = 0; v.duration = 4; v.srcDuration = 10; v.speed = 0.5
        var img = Clip(); img.id = "i"; img.type = .image; img.src = "/nonexistent/a.png"; img.start = 5; img.duration = 2
        var fz = v; fz.id = "z"; fz.freeze = true; fz.start = 8
        p.tracks[0].clips = [v, img, fz]
        return ProjectModel(project: p)
    }

    func testModesAreExclusiveAndEachChangeIsOneUndoStep() throws {
        let m = model()
        let um = m.effectiveUndoManager
        let original = try m.project.encoded()
        XCTAssertTrue(m.setFrameInterpolation(.flow, clipId: "v"))
        XCTAssertEqual(m.clip("v")?.frameFlow, true); XCTAssertNil(m.clip("v")?.frameBlend)
        XCTAssertEqual(um.undoActionName, "オプティカルフロー補間")
        XCTAssertTrue(m.setFrameInterpolation(.blend, clipId: "v"))
        XCTAssertEqual(m.clip("v")?.frameBlend, true); XCTAssertNil(m.clip("v")?.frameFlow)
        XCTAssertEqual(um.undoActionName, "フレームブレンド")
        XCTAssertTrue(m.setFrameInterpolation(.none, clipId: "v"))
        XCTAssertNil(m.clip("v")?.frameBlend); XCTAssertNil(m.clip("v")?.frameFlow)
        XCTAssertEqual(try m.project.encoded(), original, "なしに戻せば、ファイルは元のまま")
        um.undo(); XCTAssertEqual(m.clip("v")?.frameBlend, true)
        um.undo(); XCTAssertEqual(m.clip("v")?.frameFlow, true)
        um.undo(); XCTAssertEqual(try m.project.encoded(), original)
        XCTAssertFalse(um.canUndo, "3 回の変更 = 3 回の Undo")
    }

    func testSameModeAndUnsupportedClipsDoNothing() {
        let m = model()
        let um = m.effectiveUndoManager
        XCTAssertFalse(m.setFrameInterpolation(.none, clipId: "v"), "すでに『なし』")
        XCTAssertFalse(m.setFrameInterpolation(.flow, clipId: "i"), "画像は対象外")
        XCTAssertFalse(m.setFrameInterpolation(.flow, clipId: "z"), "フリーズは対象外")
        XCTAssertFalse(m.setFrameInterpolation(.flow, clipId: "missing"))
        m.setFrameInterpolation(.flow, clipId: "v")
        um.removeAllActions()
        XCTAssertFalse(m.setFrameInterpolation(.flow, clipId: "v"), "すでにフロー")
        XCTAssertFalse(um.canUndo)
        m.isExporting = true
        XCTAssertFalse(m.setFrameInterpolation(.blend, clipId: "v"), "書き出し中は触れない")
    }

    func testOldBlendToggleKeepsWorking() {
        let m = model()
        XCTAssertTrue(m.setFrameBlend(true, clipId: "v"))
        XCTAssertEqual(m.clip("v")?.frameInterpolation, .blend)
        m.setFrameInterpolation(.flow, clipId: "v")
        XCTAssertTrue(m.setFrameBlend(false, clipId: "v"), "ブレンドのチェックを外すとフローも外れる")
        XCTAssertEqual(m.clip("v")?.frameInterpolation, FrameInterpolation.none)
        XCTAssertFalse(m.setFrameBlend(false, clipId: "v"))
    }

    func testLabelsAreJapanese() {
        XCTAssertEqual(FrameInterpolation.allCases.map(\.label), ["なし", "ブレンド（重ね合わせ）", "オプティカルフロー（動きに沿う）"])
    }
}
