import XCTest
import MovieCutCore
@testable import MovieCut

/// クリップ ▸ フィラー語をカット…(選んだ区間をカット。Undo は 1 回。区間が無ければ何もしない)。
@MainActor
final class FillerCutAppTests: XCTestCase {
    private func undoSteps(_ m: ProjectModel, keep id: String) -> Int { let u = m.effectiveUndoManager; var n = 0; while u.canUndo { u.undo(); n += 1 }; for _ in 0..<n { u.redo() }; m.selectedClipId = id; return n }

    private func makeModel() -> (ProjectModel, String) {
        var a = Clip(); a.id = "a1"; a.type = .audio; a.start = 0; a.duration = 4; a.src = "tone.wav"
        var t = Track(name: "音"); t.clips = [a]
        var p = Project.new(); p.tracks = [t]
        let m = ProjectModel(project: p)
        m.selectedClipId = "a1"
        return (m, "a1")
    }

    func testCutFillersIsOneUndoStep() {
        let (m, id) = makeModel()
        let base = undoSteps(m, keep: id)
        XCTAssertTrue(m.cutFillers(clipId: id, ranges: [FillerRange(text: "えー", start: 1, end: 1.5)], ripple: true))
        XCTAssertGreaterThan(m.project.tracks[0].clips.count, 1)
        XCTAssertEqual(undoSteps(m, keep: id), base + 1)
    }

    func testEmptyRangesRegistersNothing() {
        let (m, id) = makeModel()
        let base = undoSteps(m, keep: id)
        XCTAssertFalse(m.cutFillers(clipId: id, ranges: [], ripple: true))
        XCTAssertEqual(undoSteps(m, keep: id), base)
        XCTAssertEqual(m.project.tracks[0].clips.count, 1)
    }

    func testRangeCoveringWholeClipIsRefused() {
        let (m, id) = makeModel()
        XCTAssertFalse(m.cutFillers(clipId: id, ranges: [FillerRange(text: "えー", start: 0, end: 4)], ripple: true))
        XCTAssertEqual(m.project.tracks[0].clips.count, 1)
    }
}
