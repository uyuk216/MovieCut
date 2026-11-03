import XCTest
import AppKit
import MovieCutCore
@testable import MovieCut

/// 選択クリップを別プロジェクトへ複製(候補 37)。元は変えず、行き先は 1 回の Undo。
@MainActor
final class TransferClipsAppTests: XCTestCase {
    private func source() -> ProjectModel {
        var p = Project.new()
        var a = Clip(); a.id = "a"; a.type = .image; a.src = "/m/a.png"; a.start = 4; a.duration = 3
        var b = Clip(); b.id = "b"; b.type = .text; b.text = "題"; b.start = 5; b.duration = 2
        p.tracks[0].clips = [a]
        p.tracks[3].clips = [b]
        let m = ProjectModel(project: p)
        m.setSelection(ClipSelection(ids: ["a", "b"], primary: "a"))
        return m
    }

    func testMenuItemStateAndReason() throws {
        let m = source()
        var s = MenuState(model: m)
        let item = try XCTUnwrap(AppMenuSpec.clipCompareAndTransfer(s).first { $0.command == .transferClips })
        XCTAssertTrue(item.enabled); XCTAssertNil(item.shortcut)
        m.setSelection(ClipSelection(ids: [], primary: nil))
        s = MenuState(model: m)
        let off = try XCTUnwrap(AppMenuSpec.clipCompareAndTransfer(s).first { $0.command == .transferClips })
        XCTAssertFalse(off.enabled)
        XCTAssertNotNil(AppMenuSpec.disabledReason(for: off, state: s))
    }

    func testTransferToOtherDocumentKeepsPlacementAndIsOneUndoThere() throws {
        let src = source()
        let dest = ProjectModel(project: .new())
        let srcBefore = try src.project.encoded()
        let destBefore = try dest.project.encoded()
        XCTAssertEqual(src.transferSelection(to: dest), 2)
        XCTAssertEqual(try src.project.encoded(), srcBefore, "元は変えない")
        XCTAssertFalse(src.effectiveUndoManager.canUndo)
        XCTAssertEqual(dest.project.tracks[0].clips.map(\.start), [4])
        XCTAssertEqual(dest.project.tracks[3].clips.map(\.start), [5])
        XCTAssertEqual(dest.selectedClipIDs.count, 2)
        XCTAssertEqual(dest.effectiveUndoManager.undoActionName, "別のプロジェクトから複製")
        dest.effectiveUndoManager.undo()
        XCTAssertFalse(dest.effectiveUndoManager.canUndo, "行き先は 1 回で元に戻る")
        XCTAssertEqual(try dest.project.encoded(), destBefore)
        XCTAssertEqual(src.transferSelection(to: src), 0, "自分自身へは複製しない")
    }

    func testTransferToLockedDestinationIsNoOp() throws {
        let src = source()
        let dest = ProjectModel(project: .new())
        for i in dest.project.tracks.indices { dest.project.tracks[i].locked = true }
        XCTAssertEqual(src.transferSelection(to: dest), 0)
        XCTAssertFalse(dest.effectiveUndoManager.canUndo)
    }

    func testOpenProjectsRegistryTracksModelsWithWindows() {
        let a = ProjectModel(project: .new()), b = ProjectModel(project: .new())
        XCTAssertFalse(OpenProjects.others(excluding: a).contains { $0 === b }, "ウインドウの無い書類は出さない")
        b.window = NSWindow()
        XCTAssertTrue(OpenProjects.others(excluding: a).contains { $0 === b })
        XCTAssertFalse(OpenProjects.others(excluding: b).contains { $0 === b })
        b.shutdown()
        XCTAssertFalse(OpenProjects.others(excluding: a).contains { $0 === b })
    }

    func testNewDocumentHandsPackageThroughInbox() throws {
        _ = TemplateInbox.take()
        let src = source()
        let pk = try XCTUnwrap(ClipTransfer.extract(from: src.project, clipIds: ["a", "b"]))
        TemplateInbox.set(pk.project)
        let got = try XCTUnwrap(TemplateInbox.take())
        XCTAssertEqual(got.tracks[0].clips.map(\.start), [4])
        XCTAssertEqual(got.tracks[3].clips.map(\.start), [5])
    }
}
