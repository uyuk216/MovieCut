import XCTest
import MovieCutCore
@testable import MovieCut

/// 音声ビジュアライザ(クリップ ▸ 音声ビジュアライザを追加): 1 操作 = 1 Undo、一番上のレイヤーに置く、ショートカットなしのメニュー項目。
@MainActor
final class VisualizerAppTests: XCTestCase {
    private func makeModel() -> ProjectModel {
        var p = Project.new()
        var i = Clip(); i.id = "i"; i.type = .image; i.start = 0; i.duration = 4; i.src = "/tmp/none.png"
        p.tracks[0].clips = [i]
        let m = ProjectModel(project: p)
        m.notices = OneTimeNotices()
        return m
    }

    func testAddVisualizerIsOneUndoStepOnTopLayerAndSelected() {
        let m = makeModel()
        m.currentTime = 1.5
        AppMenu.perform(.addVisualizer, model: m)
        let top = m.project.tracks[m.project.tracks.count - 1].clips.last
        XCTAssertEqual(top?.type, .visualizer)
        XCTAssertEqual(top?.start, 1.5)
        XCTAssertNil(top?.visualizer, "既定の見た目は項目を書かない")
        XCTAssertEqual(m.selectedClipId, top?.id)
        XCTAssertEqual(m.effectiveUndoManager.undoActionName, "ビジュアライザの追加")
        m.effectiveUndoManager.undo()
        XCTAssertFalse(m.project.tracks.flatMap(\.clips).contains { $0.type == .visualizer })
    }

    func testMenuItemIsInClipMenuWithoutShortcut() {
        var s = MenuState(); s.hasDocument = true
        let item = AppMenuSpec.clipAdd(s).first { $0.command == .addVisualizer }
        XCTAssertEqual(item?.title, "音声ビジュアライザを追加")
        XCTAssertNil(item?.shortcut)
        XCTAssertEqual(item?.enabled, true)
    }

    func testInspectorStyleChangeIsOneUndoStepAndDefaultsAreNotWritten() {
        let m = makeModel()
        m.currentTime = 0
        let id = m.addVisualizerClip()!
        m.setClipProperty({ $0.visualizer = ClipInspector.vizUpdated($0.visualizer) { $0.style = "wave" } }, name: "ビジュアライザの形の変更", clipId: id)
        XCTAssertEqual(m.clip(id)?.visualizer, Visualizer(style: "wave"))
        // 既定の色・本数・形に戻したら、項目ごと外れる
        m.setClipProperty({ $0.visualizer = ClipInspector.vizUpdated($0.visualizer) { $0.style = "bars" } }, name: "戻す", clipId: id)
        XCTAssertNil(m.clip(id)?.visualizer)
        XCTAssertNil(ClipInspector.vizUpdated(nil) { $0.count = 32 }, "既定の本数は書かない")
        XCTAssertEqual(ClipInspector.vizUpdated(nil) { $0.count = 12 }, Visualizer(count: 12))
    }

    func testSpectrumModeAndSourceAreOneUndoStepAndDefaultsAreNotWritten() {
        let m = makeModel()
        m.currentTime = 0
        let id = m.addVisualizerClip()!
        m.setClipProperty({ $0.visualizer = ClipInspector.vizUpdated($0.visualizer) { $0.mode = "spectrum" } }, name: "ビジュアライザの見方の変更", clipId: id)
        XCTAssertEqual(m.clip(id)?.visualizer, Visualizer(mode: "spectrum"))
        m.setClipProperty({ $0.visualizer = ClipInspector.vizUpdated($0.visualizer) { $0.source = "clip-1" } }, name: "ビジュアライザの入力音声の変更", clipId: id)
        XCTAssertEqual(m.clip(id)?.visualizer, Visualizer(mode: "spectrum", source: "clip-1"))
        m.effectiveUndoManager.undo()
        XCTAssertEqual(m.clip(id)?.visualizer, Visualizer(mode: "spectrum"))
        m.setClipProperty({ $0.visualizer = ClipInspector.vizUpdated($0.visualizer) { $0.mode = "level" } }, name: "戻す", clipId: id)
        XCTAssertNil(m.clip(id)?.visualizer, "音量(既定)に戻したら項目ごと外れる")
        XCTAssertNil(ClipInspector.vizUpdated(nil) { $0.source = "" }, "空の音声指定は書かない")
    }
}
