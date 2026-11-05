import XCTest
import MovieCutCore
@testable import MovieCut

/// 音階で複製・ビートに合わせて並べる: メニュー表、1 回の Undo、無効の理由、選択。
@MainActor
final class PitchLayoutAppTests: XCTestCase {
    private func makeModel(markers: [Double] = []) -> ProjectModel {
        var p = Project.new()
        var a = Clip(); a.id = "a"; a.type = .audio; a.src = "/tmp/none.wav"; a.start = 1; a.duration = 0.5; a.srcDuration = 3; a.volume = 1
        var i = Clip(); i.id = "i"; i.type = .image; i.src = "/tmp/none.png"; i.start = 0; i.duration = 1
        p.tracks[0].clips = [a]
        p.tracks[1].clips = [i]
        p.markers = markers.map { Marker(time: $0, name: "ビート") }
        let m = ProjectModel(project: p)
        m.notices = OneTimeNotices()
        return m
    }

    private func state(_ configure: (inout MenuState) -> Void = { _ in }) -> MenuState {
        var s = MenuState()
        s.hasDocument = true; s.canExport = true
        s.resolutionKey = "1920x1080"; s.codec = "h264"; s.bg = "#000000"
        configure(&s)
        return s
    }

    func testMenuItemsAndReasons() {
        let s0 = state()
        for item in [AppMenuSpec.scaleDuplicateItem(s0), AppMenuSpec.beatPlaceItem(s0)] {
            XCTAssertNil(item.shortcut)
            XCTAssertFalse(item.enabled)
            XCTAssertNotNil(AppMenuSpec.disabledReason(for: item, state: s0))
        }
        XCTAssertEqual(AppMenuSpec.scaleDuplicateItem(s0).title, "選択クリップを音階で複製…")
        XCTAssertEqual(AppMenuSpec.beatPlaceItem(s0).title, "ビートに合わせてクリップを並べる…")
        let s1 = state { $0.canPitchLayout = true }
        XCTAssertTrue(AppMenuSpec.scaleDuplicateItem(s1).enabled)
        let b1 = AppMenuSpec.beatPlaceItem(s1)
        XCTAssertFalse(b1.enabled)
        XCTAssertTrue(AppMenuSpec.disabledReason(for: b1, state: s1)!.contains("マーカー"))
        XCTAssertTrue(AppMenuSpec.beatPlaceItem(state { $0.canPitchLayout = true; $0.canBeatPlace = true }).enabled)
        let all = AppMenuSpec.all(s1)
        XCTAssertTrue(all.contains { $0.command == .scaleDuplicate })
        XCTAssertTrue(all.contains { $0.command == .beatPlace })
    }

    func testMenuStateFollowsSelection() {
        let m = makeModel(markers: [2, 3])
        var s = MenuState(model: m)
        XCTAssertFalse(s.canPitchLayout)
        m.selectedClipId = "i"; s = MenuState(model: m)
        XCTAssertFalse(s.canPitchLayout, "画像は対象外")
        m.selectedClipId = "a"; s = MenuState(model: m)
        XCTAssertTrue(s.canPitchLayout); XCTAssertTrue(s.canBeatPlace)
        m.project.markers = []
        s = MenuState(model: m)
        XCTAssertTrue(s.canPitchLayout); XCTAssertFalse(s.canBeatPlace)
    }

    func testScaleDuplicateIsOneUndoStep() {
        let m = makeModel()
        m.selectedClipId = "a"
        let before = m.project
        m.openScaleSheet()
        XCTAssertTrue(m.showScaleSheet)
        XCTAssertTrue(m.applyScaleDuplicate(clipId: "a", scale: .major, rootShift: 0, count: 7, descending: false))
        XCTAssertEqual(m.project.tracks[0].clips.count, 7)
        XCTAssertEqual(m.selectedClipIDs.count, 7)
        XCTAssertEqual(m.effectiveUndoManager.undoActionName, "音階で複製")
        m.effectiveUndoManager.undo()
        XCTAssertEqual(m.project, before, "1 回の Undo で全部戻る")
        XCTAssertFalse(m.effectiveUndoManager.canUndo)
    }

    func testBeatPlaceIsOneUndoStepAndNeedsMarkers() {
        let m = makeModel()
        m.selectedClipId = "a"
        m.openBeatPlaceSheet()
        XCTAssertFalse(m.showBeatPlaceSheet, "マーカーが無ければ開かない")
        XCTAssertFalse(m.applyBeatPlace(clipId: "a", beatsOnly: false, pitchStep: 1, limit: 0))
        XCTAssertFalse(m.effectiveUndoManager.canUndo)
        m.project.markers = [2, 2.25, 3].map { Marker(time: $0, name: "ビート") }
        let before = m.project
        XCTAssertTrue(m.applyBeatPlace(clipId: "a", beatsOnly: true, pitchStep: 2, limit: 0))
        XCTAssertEqual(m.project.tracks[0].clips.map(\.start), [2, 2.25, 3])
        XCTAssertEqual(m.project.tracks[0].clips.map(\.duration), [0.25, 0.5, 0.5])
        XCTAssertEqual(m.effectiveUndoManager.undoActionName, "ビートに合わせて並べる")
        m.effectiveUndoManager.undo()
        XCTAssertEqual(m.project, before)
    }

    func testLockedLayerRefuses() {
        let m = makeModel(markers: [2])
        m.project.tracks[0].locked = true
        m.selectedClipId = "a"
        m.openScaleSheet()
        XCTAssertFalse(m.showScaleSheet)
        XCTAssertFalse(m.applyScaleDuplicate(clipId: "a", scale: .major, rootShift: 0, count: 3, descending: false))
    }
}
