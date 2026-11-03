import XCTest
import MovieCutCore
@testable import MovieCut

/// 候補クリップの比較・差し替え(候補 36)のモデル操作。仮の反映は Undo に載せず、確定は全体で 1 回。
@MainActor
final class CandidateSwapAppTests: XCTestCase {
    private func model() -> ProjectModel {
        var p = Project.new()
        var v = Clip(); v.id = "v"; v.type = .video; v.src = "/m/a.mov"; v.srcDuration = 20; v.start = 1; v.duration = 6; v.offset = 2
        p.tracks[0].clips = [v]
        p.mediaPool = ["/m/a.mov", "/m/b.mov", "/m/c.mov"]
        let m = ProjectModel(project: p)
        m.candidateProbe = { url, _ in url.lastPathComponent == "c.mov" ? 3 : 30 }
        m.selectedClipId = "v"
        return m
    }

    func testMenuItemStateAndReason() throws {
        let m = model()
        var s = MenuState(model: m)
        let item = try XCTUnwrap(AppMenuSpec.clipCompareAndTransfer(s).first { $0.command == .candidateSwap })
        XCTAssertTrue(item.enabled); XCTAssertNil(item.shortcut)
        m.selectedClipId = nil
        s = MenuState(model: m)
        let off = try XCTUnwrap(AppMenuSpec.clipCompareAndTransfer(s).first { $0.command == .candidateSwap })
        XCTAssertFalse(off.enabled)
        XCTAssertNotNil(AppMenuSpec.disabledReason(for: off, state: s))
        AppMenu.perform(.candidateSwap, model: m)
        XCTAssertNil(m.candidateSession)
    }

    func testPreviewDoesNotRegisterUndoAndCommitIsOneStep() async throws {
        let m = model()
        let before = try m.project.encoded()
        XCTAssertTrue(m.openCandidateSwap())
        XCTAssertEqual(m.currentCandidates().map(\.name), ["b.mov", "c.mov"])
        let ok1 = await m.previewCandidate("/m/b.mov")
        XCTAssertTrue(ok1)
        XCTAssertEqual(m.clip("v")?.src, "/m/b.mov")
        let ok2 = await m.previewCandidate("/m/c.mov")
        XCTAssertTrue(ok2)
        XCTAssertEqual(m.clip("v")?.src, "/m/c.mov")
        XCTAssertEqual(m.clip("v")?.duration ?? 0, 3, accuracy: 1e-9, "短い素材なら長さを詰める")
        XCTAssertFalse(m.effectiveUndoManager.canUndo, "仮の反映は Undo に載せない")
        let ok3 = await m.previewCandidate(nil)
        XCTAssertTrue(ok3)
        XCTAssertEqual(try m.project.encoded(), before, "元の素材に戻せる")
        _ = await m.previewCandidate("/m/b.mov")
        XCTAssertTrue(m.commitCandidateSwap())
        XCTAssertNil(m.candidateSession)
        XCTAssertEqual(m.clip("v")?.src, "/m/b.mov")
        XCTAssertEqual(m.effectiveUndoManager.undoActionName, "候補クリップに差し替え")
        m.effectiveUndoManager.undo()
        XCTAssertFalse(m.effectiveUndoManager.canUndo, "1 回で元に戻る")
        XCTAssertEqual(try m.project.encoded(), before)
    }

    func testCancelRestoresAndRegistersNothing() async throws {
        let m = model()
        let before = try m.project.encoded()
        XCTAssertTrue(m.openCandidateSwap())
        _ = await m.previewCandidate("/m/b.mov")
        m.cancelCandidateSwap()
        XCTAssertNil(m.candidateSession)
        XCTAssertEqual(try m.project.encoded(), before)
        XCTAssertFalse(m.effectiveUndoManager.canUndo)
        XCTAssertNil(m.gestureBase)
    }

    func testCommitWithoutChoiceChangesNothing() throws {
        let m = model()
        XCTAssertTrue(m.openCandidateSwap())
        XCTAssertFalse(m.commitCandidateSwap())
        XCTAssertFalse(m.effectiveUndoManager.canUndo)
    }

    func testAddedFilesBecomeCandidatesAndRegisterInPoolOnCommit() async throws {
        let m = model()
        XCTAssertTrue(m.openCandidateSwap())
        XCTAssertEqual(m.addCandidateFiles([URL(fileURLWithPath: "/n/new.mov"), URL(fileURLWithPath: "/n/pic.png"), URL(fileURLWithPath: "/m/b.mov")]), 1)
        XCTAssertEqual(m.currentCandidates().map(\.name), ["b.mov", "c.mov", "new.mov"])
        _ = await m.previewCandidate("/n/new.mov")
        XCTAssertTrue(m.commitCandidateSwap())
        XCTAssertTrue(m.project.mediaPool.contains("/n/new.mov"))
    }

    func testCannotOpenForLockedOrMissingCandidates() {
        let m = model()
        m.project.tracks[0].clips[0].locked = true
        XCTAssertFalse(m.openCandidateSwap())
        let m2 = model()
        m2.project.mediaPool = ["/m/a.mov"]
        XCTAssertFalse(m2.openCandidateSwap(), "候補が無い")
    }
}
