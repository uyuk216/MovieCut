import XCTest
import MovieCutCore
@testable import MovieCut

/// クリップ ▸ 分割点を統合(候補 34)。1 回の Undo、選択があればその周りだけ。
@MainActor
final class MergeSplitsAppTests: XCTestCase {
    private func model() throws -> (ProjectModel, [Clip]) {
        var c = Clip(); c.id = "v"; c.type = .video; c.src = "/nonexistent/a.mov"; c.srcDuration = 60; c.start = 0; c.duration = 9
        let (a, rest) = try XCTUnwrap(ClipEditing.split(c, at: 3))
        let (b, d) = try XCTUnwrap(ClipEditing.split(rest, at: 6))
        var other = c; other.id = "o"; other.src = "/nonexistent/b.mov"; other.start = 20; other.duration = 2
        var p = Project.new()
        p.tracks[0].clips = [a, b, d, other]
        return (ProjectModel(project: p), [a, b, d])
    }

    func testMergesEverythingWithOneUndo() throws {
        let (m, parts) = try model()
        let before = try m.project.encoded()
        var s = MenuState(model: m)
        XCTAssertTrue(AppMenuSpec.clipTrim(s).first { $0.command == .mergeSplits }!.enabled)
        XCTAssertTrue(m.mergeSplitPoints())
        XCTAssertEqual(m.project.tracks[0].clips.map(\.id), [parts[0].id, "o"])
        XCTAssertEqual(m.selectedClipId, parts[0].id)
        XCTAssertEqual(m.statusText, "2 個の分割点を統合しました")
        XCTAssertEqual(m.effectiveUndoManager.undoActionName, "分割点を統合")
        m.effectiveUndoManager.undo()
        XCTAssertFalse(m.effectiveUndoManager.canUndo, "1 回で元に戻る")
        XCTAssertEqual(try m.project.encoded(), before)
        m.effectiveUndoManager.redo()
        s = MenuState(model: m)
        XCTAssertFalse(AppMenuSpec.clipTrim(s).first { $0.command == .mergeSplits }!.enabled, "もう統合するものが無い")
        XCTAssertNotNil(AppMenuSpec.disabledReason(for: AppMenuSpec.clipTrim(s).first { $0.command == .mergeSplits }!, state: s))
    }

    func testNothingToMergeRegistersNoUndo() throws {
        let m = ProjectModel(project: .new())
        XCTAssertFalse(m.mergeSplitPoints())
        XCTAssertFalse(m.effectiveUndoManager.canUndo)
    }

    func testSelectionLimitsTheScope() throws {
        let (m, parts) = try model()
        m.selectedClipId = parts[2].id
        XCTAssertTrue(m.mergeSplitPoints())
        XCTAssertEqual(m.project.tracks[0].clips.count, 3, "選んだクリップの前とだけ統合")
        m.selectedClipId = "o"
        XCTAssertFalse(m.mergeSplitPoints(), "選んだクリップの周りに統合できるものが無い")
    }

    func testLockedLayerIsRefused() throws {
        let (m, _) = try model()
        m.project.tracks[0].locked = true
        XCTAssertFalse(m.mergeSplitPoints())
        XCTAssertEqual(m.project.tracks[0].clips.count, 4)
    }
}
