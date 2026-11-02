import XCTest
import MovieCutCore
@testable import MovieCut

@MainActor
final class TrimLoopAppTests: XCTestCase {
    private func model(end: Double = 10) -> ProjectModel {
        var p = Project.new()
        var c = Clip(); c.type = .voice; c.src = "/tmp/a.wav"; c.start = 2; c.duration = end - 2
        p.tracks[0].clips.append(c)
        return ProjectModel(project: p)
    }

    func testActiveLoopRangeUsesTrimLoopFirst() {
        let m = model()
        m.trimLoop = ExportRange(start: 1, end: 3)
        XCTAssertEqual(m.activeLoopRange, ExportRange(start: 1, end: 3))
        m.trimLoop = nil
        XCTAssertNil(m.activeLoopRange)
    }

    func testSettingPersistsAndNormalizes() {
        let old = UserDefaults.standard.object(forKey: TrimLoopSettings.key)
        defer { if let old { UserDefaults.standard.set(old, forKey: TrimLoopSettings.key) } else { UserDefaults.standard.removeObject(forKey: TrimLoopSettings.key) } }
        UserDefaults.standard.removeObject(forKey: TrimLoopSettings.key)
        XCTAssertEqual(TrimLoopSettings.halfWidth, 1)
        TrimLoopSettings.halfWidth = 2
        XCTAssertEqual(TrimLoopSettings.halfWidth, 2)
        TrimLoopSettings.halfWidth = 7
        XCTAssertEqual(TrimLoopSettings.halfWidth, 1)
    }

    func testMenuItemsReasonsAndChecks() {
        var s = MenuState(); s.hasDocument = true
        let items = AppMenuSpec.playback(s)
        let trim = items.first { $0.command == .toggleTrimLoop }!
        let clip = items.first { $0.command == .toggleClipLoop }!
        XCTAssertFalse(trim.enabled)
        XCTAssertEqual(AppMenuSpec.disabledReason(for: trim, state: s), "タイムラインが空です")
        s.hasClips = true
        XCTAssertTrue(AppMenuSpec.playback(s).first { $0.command == .toggleTrimLoop }!.enabled)
        XCTAssertEqual(AppMenuSpec.disabledReason(for: clip, state: s), "クリップを選んでください")
        s.hasSelection = true
        XCTAssertTrue(AppMenuSpec.playback(s).first { $0.command == .toggleClipLoop }!.enabled)
        s.trimLoopHalfWidth = 2
        let w = AppMenuSpec.trimLoopWidthItems(s)
        XCTAssertEqual(w.map { $0.checked }, [false, false, true])
        XCTAssertTrue(w.allSatisfy { $0.shortcut == nil })
    }

    func testToggleTrimLoopStartsAndStops() {
        let m = model()
        m.currentTime = 5
        m.toggleTrimLoop()
        XCTAssertNotNil(m.trimLoop)
        XCTAssertEqual(m.currentTime, m.trimLoop!.start, accuracy: 1e-9)
        m.toggleTrimLoop()
        XCTAssertNil(m.trimLoop)
        XCTAssertFalse(m.playback.isPlaying)
    }

    func testClipLoopNeedsSelection() {
        let m = model()
        m.toggleClipLoop()
        XCTAssertNil(m.trimLoop)
        m.selectedClipId = m.project.allClips[0].id
        m.toggleClipLoop()
        XCTAssertEqual(m.trimLoop, ExportRange(start: 2, end: 10))
    }

    func testNoUndoEntry() {
        let m = model()
        m.toggleTrimLoop()
        XCTAssertFalse(m.effectiveUndoManager.canUndo)
    }
}
