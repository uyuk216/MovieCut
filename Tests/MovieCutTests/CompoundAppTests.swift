import XCTest
import MovieCutCore
@testable import MovieCut

/// 複合クリップのメニュー(仕様表・ショートカットなし)と、モデルのまとめ・解除(1 操作 = 1 回の Undo)。
@MainActor
final class CompoundAppTests: XCTestCase {

    private func clip(_ id: String, start: Double) -> Clip {
        var c = Clip(); c.id = id; c.type = .image; c.start = start; c.duration = 2
        return c
    }

    private func makeModel() -> ProjectModel {
        var p = Project.new()
        p.tracks[0].clips = [clip("a", start: 0)]
        p.tracks[1].clips = [clip("b", start: 1)]
        let m = ProjectModel(project: p)
        m.notices = OneTimeNotices()
        return m
    }

    /// 取り消せる回数(Undo を全部使って数え、やり直して戻す)。
    private func undoSteps(_ m: ProjectModel) -> Int {
        let u = m.effectiveUndoManager
        var n = 0
        while u.canUndo { u.undo(); n += 1 }
        for _ in 0..<n { u.redo() }
        return n
    }

    private func state(_ configure: (inout MenuState) -> Void = { _ in }) -> MenuState {
        var s = MenuState()
        s.hasDocument = true; s.canExport = true
        s.resolutionKey = "1920x1080"; s.codec = "h264"; s.bg = "#000000"
        configure(&s)
        return s
    }

    func testMenuItemsAreInClipEditWithoutShortcuts() throws {
        let items = AppMenuSpec.clipEdit(state { $0.hasSelection = true; $0.selectionCount = 2; $0.canCompoundGroup = true })
        let group = try XCTUnwrap(items.first { $0.command == .compoundGroup })
        XCTAssertEqual(group.title, "複合クリップにまとめる")
        XCTAssertTrue(group.enabled)
        XCTAssertNil(group.shortcut, "ショートカットは持たない")
        let ungroup = try XCTUnwrap(items.first { $0.command == .compoundUngroup })
        XCTAssertEqual(ungroup.title, "複合クリップを解除")
        XCTAssertFalse(ungroup.enabled, "複合クリップを選んでいないときは使えない")
        let on = AppMenuSpec.clipEdit(state { $0.canCompoundUngroup = true })
        XCTAssertTrue(try XCTUnwrap(on.first { $0.command == .compoundUngroup }).enabled)
    }

    func testGroupIsOneUndoStepAndSelectsTheCompound() throws {
        let m = makeModel()
        m.selectedClipIDs = ["a", "b"]
        m.selectedClipId = "a"
        XCTAssertTrue(m.groupSelectedCompound())
        let comp = try XCTUnwrap(m.project.allClips.first { $0.type == .compound })
        XCTAssertEqual(m.selectedClipId, comp.id)
        XCTAssertEqual(undoSteps(m), 1, "まとめは 1 回の Undo")
        m.effectiveUndoManager.undo()
        XCTAssertEqual(m.project.allClips.map(\.id).sorted(), ["a", "b"], "Undo で元に戻る")
    }

    func testUngroupIsOneUndoStepAndSelectsRestoredClips() throws {
        let m = makeModel()
        let before = m.project
        m.selectedClipIDs = ["a", "b"]; m.selectedClipId = "a"
        XCTAssertTrue(m.groupSelectedCompound())
        let comp = try XCTUnwrap(m.project.allClips.first { $0.type == .compound })
        m.selectOnly(comp.id)
        XCTAssertTrue(m.ungroupSelectedCompound())
        XCTAssertEqual(m.project, before, "解除すると元の並び・値に戻る")
        XCTAssertEqual(m.selectedClipIDs, ["a", "b"])
        XCTAssertEqual(undoSteps(m), 2, "まとめと解除は、それぞれ 1 回")
    }

    func testGroupNeedsTwoSelectedClips() {
        let m = makeModel()
        m.selectOnly("a")
        XCTAssertFalse(m.groupSelectedCompound())
        XCTAssertEqual(undoSteps(m), 0)
    }

    func testMenuPerformRunsGroupAndUngroup() throws {
        let m = makeModel()
        m.selectedClipIDs = ["a", "b"]; m.selectedClipId = "a"
        AppMenu.perform(.compoundGroup, model: m)
        let comp = try XCTUnwrap(m.project.allClips.first { $0.type == .compound })
        AppMenu.perform(.compoundUngroup, model: m)
        XCTAssertFalse(m.project.allClips.contains { $0.type == .compound })
        XCTAssertNotNil(m.clip("a"))
        _ = comp
    }
}
