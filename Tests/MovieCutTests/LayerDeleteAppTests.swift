import XCTest
import MovieCutCore
@testable import MovieCut

/// レイヤーの削除(メニュー項目表・確認ダイアログ・Undo・選択)。
@MainActor
final class LayerDeleteAppTests: XCTestCase {
    private var asked: [(String, Int, Bool)] = []
    private var answer = true
    private var saved: (@MainActor (String, Int, Bool) -> Bool)!

    override func setUp() async throws {
        saved = ProjectModel.confirmLayerDelete
        asked = []; answer = true
        ProjectModel.confirmLayerDelete = { [unowned self] n, c, l in self.asked.append((n, c, l)); return self.answer }
    }
    override func tearDown() async throws { ProjectModel.confirmLayerDelete = saved }

    private func clip(_ id: String, start: Double = 0) -> Clip {
        var c = Clip(); c.id = id; c.type = .image; c.start = start; c.duration = 1
        return c
    }

    /// T0: a b / T1: c / T2: (空) / T3: d(ロック)
    private func makeModel() -> ProjectModel {
        var p = Project.new()
        p.tracks[0].clips = [clip("a"), clip("b", start: 2)]
        p.tracks[1].clips = [clip("c")]
        p.tracks[3].clips = [clip("d")]
        p.tracks[3].locked = true
        let m = ProjectModel(project: p)
        return m
    }

    private func state(_ m: ProjectModel) -> MenuState {
        var s = MenuState(model: m); s.hasDocument = true; return s
    }

    func testMenuItemIsInSpecTableWithNoShortcutAndNoDuplicates() {
        let m = makeModel(); m.selectLayer(0)
        let item = AppMenuSpec.layerDeleteItem(state(m))
        XCTAssertEqual(item.title, "レイヤーを削除…")
        XCTAssertNil(item.shortcut)
        XCTAssertTrue(item.enabled)
        XCTAssertTrue(AppMenuSpec.all(state(m)).contains { $0.command == .layerDelete })
    }

    func testDisabledWithoutTargetAndForLastLayerWithReason() {
        let m = makeModel()
        var s = state(m)
        XCTAssertFalse(AppMenuSpec.layerDeleteItem(s).enabled, "対象のレイヤーがない")
        XCTAssertEqual(AppMenuSpec.disabledReason(for: AppMenuSpec.layerDeleteItem(s), state: s), "レイヤーかクリップを選んでください")
        var p = m.project; p.tracks = [p.tracks[0]]
        let one = ProjectModel(project: p); one.selectLayer(0)
        s = state(one)
        let it = AppMenuSpec.layerDeleteItem(s)
        XCTAssertFalse(it.enabled)
        XCTAssertEqual(AppMenuSpec.disabledReason(for: it, state: s), "最後のレイヤーは削除できません")
        AppMenu.perform(.layerDelete, model: one)
        XCTAssertEqual(one.project.tracks.count, 1)
        XCTAssertTrue(asked.isEmpty)
    }

    func testDeleteWithClipsAsksThenOneUndoStep() {
        let m = makeModel(); let before = m.project
        m.selectLayer(0)
        AppMenu.perform(.layerDelete, model: m)
        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(asked[0].1, 2)
        XCTAssertFalse(asked[0].2)
        XCTAssertEqual(m.project.tracks.count, before.tracks.count - 1)
        XCTAssertNil(m.selectedLayerIndex)
        XCTAssertEqual(m.effectiveUndoManager.undoActionName, "レイヤーの削除")
        m.effectiveUndoManager.undo()
        XCTAssertEqual(m.project, before, "1 回で元に戻る")
        XCTAssertFalse(m.effectiveUndoManager.canUndo)
        assertNoLayerOverlaps(m.project)
    }

    func testCancelKeepsEverythingAndNoUndoEntry() {
        let m = makeModel(); let before = m.project
        answer = false
        m.selectLayer(0)
        XCTAssertFalse(m.requestDeleteLayer(0))
        XCTAssertEqual(m.project, before)
        XCTAssertFalse(m.effectiveUndoManager.canUndo)
    }

    func testEmptyLayerDeletesWithoutAsking() {
        let m = makeModel()
        XCTAssertTrue(m.requestDeleteLayer(2))
        XCTAssertTrue(asked.isEmpty)
        XCTAssertEqual(m.project.tracks.count, 4)
    }

    func testLockedLayerAsksAndStatesLockedThenDeletes() {
        let m = makeModel()
        XCTAssertTrue(m.requestDeleteLayer(3))
        XCTAssertEqual(asked.count, 1)
        XCTAssertTrue(asked[0].2, "ロック中であることを確認文に入れる")
        XCTAssertFalse(m.project.allClips.contains { $0.id == "d" })
        m.effectiveUndoManager.undo()
        XCTAssertTrue(m.project.tracks[3].isLocked)
        XCTAssertTrue(m.project.allClips.contains { $0.id == "d" })
    }

    func testSelectionIsPrunedAndLayerSelectionFollowsUndo() {
        let m = makeModel()
        m.selectOnly("a")
        AppMenu.perform(.layerDelete, model: m)       // 選択クリップのレイヤー(= 0)
        XCTAssertNil(m.selectedClipId)
        XCTAssertTrue(m.selectedClipIDs.isEmpty)
        m.effectiveUndoManager.undo()
        m.selectLayer(2)
        m.effectiveUndoManager.redo()                  // 0 を消す → 2 番は別のレイヤーになる
        XCTAssertNil(m.selectedLayerIndex)
    }

    func testContextMenuHasDeleteAndRunsIt() {
        let m = makeModel()
        let canvas = TimelineCanvas(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        canvas.model = m
        let menu = canvas.layerContextMenu(row: 1)!
        let item = menu.items.first { $0.title == "レイヤーを削除…" }!
        XCTAssertTrue(item.isEnabled)
        (item.target as? MenuAction)?.run()
        XCTAssertEqual(m.project.tracks.count, 4)
        XCTAssertEqual(asked.first?.1, 1)
    }
}
