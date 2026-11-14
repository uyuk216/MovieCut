import XCTest
import MovieCutCore
@testable import MovieCut

/// グループ化の画面操作: モデル経由の付け外し(Undo 1 回)と、クリック時の選択の拡張。
@MainActor
final class GroupingAppTests: XCTestCase {
    /// レイヤー 0 に a・b、レイヤー 1 に c を置いたモデル。
    private func makeModel() -> ProjectModel {
        let m = ProjectModel(project: .new())
        var a = Clip(); a.id = "a"; a.type = .image; a.start = 0; a.duration = 2
        var b = Clip(); b.id = "b"; b.type = .image; b.start = 3; b.duration = 2
        var c = Clip(); c.id = "c"; c.type = .text; c.start = 1; c.duration = 2
        m.project.tracks[0].clips = [a, b]
        if m.project.tracks.count < 2 { m.project.tracks.append(Track(name: "下")) }
        m.project.tracks[1].clips = [c]
        return m
    }

    func testGroupAndUngroupSelectedWithUndo() {
        let m = makeModel()
        m.setSelection(ClipSelection(ids: ["a", "c"], primary: "a"))
        XCTAssertTrue(m.groupSelectedClips())
        XCTAssertEqual(m.clip("a")?.group, "group1")
        XCTAssertEqual(m.clip("c")?.group, "group1", "レイヤーをまたいで同じグループ")
        XCTAssertNil(m.clip("b")?.group)
        XCTAssertTrue(m.selectionHasGroup)

        // 解除も 1 回の Undo
        XCTAssertTrue(m.ungroupSelectedClips())
        XCTAssertNil(m.clip("a")?.group)
        XCTAssertNil(m.clip("c")?.group)
        XCTAssertFalse(m.selectionHasGroup)
        // 何も変わらない解除は Undo に積まない
        XCTAssertFalse(m.ungroupSelectedClips())

        var steps = 0
        while m.effectiveUndoManager.canUndo { m.effectiveUndoManager.undo(); steps += 1 }
        XCTAssertEqual(steps, 2, "グループ化と解除の 2 回だけ")
    }

    func testGroupNeedsTwoOrMore() {
        let m = makeModel()
        m.selectOnly("a")
        XCTAssertFalse(m.groupSelectedClips())
        XCTAssertNil(m.clip("a")?.group)
    }

    func testNextGroupIdIncrements() {
        let m = makeModel()
        m.setSelection(ClipSelection(ids: ["a", "b"], primary: "a"))
        XCTAssertTrue(m.groupSelectedClips())
        m.setSelection(ClipSelection(ids: ["b", "c"], primary: "b"))
        XCTAssertTrue(m.groupSelectedClips())
        XCTAssertEqual(m.clip("c")?.group, "group2", "2 つ目のグループは group2")
        XCTAssertEqual(m.clip("b")?.group, "group2", "付け直すと移る")
    }

    func testSelectExpandingGroup() {
        let m = makeModel()
        m.setSelection(ClipSelection(ids: ["a", "c"], primary: "a"))
        XCTAssertTrue(m.groupSelectedClips())
        m.selectOnly(nil)
        // グループのクリップを押す → 全員が選ばれる(ドラッグでまとめて動かせる状態)
        m.selectExpandingGroup("c")
        XCTAssertEqual(m.selectedClipIDs, ["a", "c"])
        XCTAssertEqual(m.selectedClipId, "c")
        // グループでないクリップは単一選択のまま
        m.selectExpandingGroup("b")
        XCTAssertEqual(m.selectedClipIDs, ["b"])
    }
}
