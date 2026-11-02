import XCTest
import MovieCutCore
@testable import MovieCut

/// 絞りぼかし: エフェクトとして追加 / ぼかし範囲の絞りの形の切り替え(1 回の Undo)。
@MainActor
final class BokehAppTests: XCTestCase {
    private func model() -> ProjectModel {
        var p = Project.new()
        var img = Clip(); img.id = "i"; img.type = .image; img.src = "/nonexistent/a.png"; img.start = 0; img.duration = 3
        var blur = Clip(); blur.id = "b"; blur.type = .blur; blur.start = 0; blur.duration = 3; blur.w = 0.4; blur.h = 0.4; blur.strength = 20
        var txt = Clip(); txt.id = "t"; txt.type = .text; txt.text = "あ"; txt.start = 0; txt.duration = 3
        p.tracks[0].clips = [img]
        p.tracks[1].clips = [blur]
        p.tracks[2].clips = [txt]
        return ProjectModel(project: p)
    }

    func testAddingTheEffectIsOneUndoStepWithDefaults() {
        let m = model()
        m.selectOnly("i")
        let um = m.effectiveUndoManager
        AppMenu.perform(.effectAdd(.bokehBlur), model: m)
        let e = m.clip("i")?.effects.last
        XCTAssertEqual(e?.known, .bokehBlur)
        XCTAssertEqual(e?.params["radius"], 20); XCTAssertEqual(e?.params["shape"], 0); XCTAssertEqual(e?.params["highlight"], 0.3)
        um.undo()
        XCTAssertTrue(m.clip("i")?.effects.isEmpty ?? false)
        XCTAssertFalse(um.canUndo)
    }

    func testEffectMenuItemIsListedWithoutShortcut() {
        var s = MenuState(); s.hasDocument = true; s.canEffect = true
        let item = AppMenuSpec.effectKindItems(s).first { $0.command == .effectAdd(.bokehBlur) }
        XCTAssertEqual(item?.title, "絞りぼかし")
        XCTAssertNil(item?.shortcut)
        XCTAssertEqual(item?.enabled, true)
    }

    func testShapeSliderShowsTheShapeNames() {
        let spec = EffectKind.bokehBlur.spec("shape")!
        XCTAssertEqual(spec.unit, .aperture)
        XCTAssertEqual(stride(from: spec.range.lowerBound, through: spec.range.upperBound, by: spec.step).map { ApertureShape(value: $0).label },
                       ["円", "三角形", "四角形", "五角形", "六角形", "八角形", "星", "ハート"])
    }

    func testRegionShapeChangeIsOneUndoStepAndCircleIsNotWritten() throws {
        let m = model()
        let um = m.effectiveUndoManager
        let original = try m.project.encoded()
        XCTAssertTrue(m.setBokehShape(.hexagon, clipId: "b"))
        XCTAssertEqual(m.clip("b")?.bokehShape, "hexagon")
        XCTAssertEqual(um.undoActionName, "絞りの形の変更")
        XCTAssertTrue(m.setBokehShape(.star, clipId: "b"))
        XCTAssertTrue(m.setBokehShape(.circle, clipId: "b"))
        XCTAssertNil(m.clip("b")?.bokehShape, "円はファイルに書かない")
        XCTAssertEqual(try m.project.encoded(), original)
        um.undo(); um.undo(); um.undo()
        XCTAssertEqual(try m.project.encoded(), original)
        XCTAssertFalse(um.canUndo)
    }

    func testRegionShapeRefusedWhenNothingChangesOrNotARegion() {
        let m = model()
        let um = m.effectiveUndoManager
        XCTAssertFalse(m.setBokehShape(.circle, clipId: "b"), "すでに円")
        XCTAssertFalse(m.setBokehShape(.star, clipId: "i"), "ぼかし範囲ではない")
        XCTAssertFalse(m.setBokehShape(.star, clipId: "missing"))
        XCTAssertFalse(um.canUndo)
        m.isExporting = true
        XCTAssertFalse(m.setBokehShape(.star, clipId: "b"), "書き出し中は触れない")
    }

    func testBlurModeSwitchToBokehIsOneUndoStep() {
        let m = model()
        let um = m.effectiveUndoManager
        m.setClipProperty({ $0.blurMode = "bokeh" }, name: "ぼかしの方式の変更", clipId: "b")
        XCTAssertEqual(m.clip("b")?.blurModeOrDefault, "bokeh")
        um.undo()
        XCTAssertNil(m.clip("b")?.blurMode)
        XCTAssertFalse(um.canUndo)
    }
}
