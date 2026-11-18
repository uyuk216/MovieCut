import XCTest
import SwiftUI
import MovieCutCore
@testable import MovieCut

/// 拡張エフェクトのアプリ配線: モデルの操作(Undo)とインスペクタ節の生成。
@MainActor
final class AudioFxExtendedAppTests: XCTestCase {
    private func makeModel() -> ProjectModel {
        var p = Project.new()
        p.fps = 60
        var c = Clip(); c.id = "m"; c.type = .audio; c.start = 0; c.duration = 6
        c.src = "/tmp/none.wav"; c.srcDuration = 6
        p.tracks[0].clips = [c]
        let m = ProjectModel(project: p)
        m.notices = OneTimeNotices()
        return m
    }

    private func undoSteps(_ m: ProjectModel) -> Int {
        let u = m.effectiveUndoManager
        var n = 0
        while u.canUndo { u.undo(); n += 1 }
        for _ in 0..<n { u.redo() }
        return n
    }

    func testExtendedEditsAreOneUndoStepEach() {
        let m = makeModel()
        let u = m.effectiveUndoManager
        m.setAudioFx({ _ = AudioFxEditing.setChorusEnabled(&$0, false) }, name: "x", clipId: "m")
        XCTAssertFalse(u.canUndo, "何も無い所を切っても履歴に載せない")
        m.setAudioFx({ _ = AudioFxEditing.setChorusEnabled(&$0, true) }, name: "コーラスの切り替え", clipId: "m")
        XCTAssertEqual(m.clip("m")?.audioFx?.extended?.chorus?.isActive, true)
        m.setAudioFx({ _ = AudioFxEditing.setFilter(&$0, kind: .lowPass, .freq, 8000) }, name: "フィルターの変更", clipId: "m")
        m.setAudioFx({ _ = AudioFxEditing.setWahAuto(&$0, true) }, name: "オートワウの切り替え", clipId: "m")
        XCTAssertEqual(undoSteps(m), 3)
        m.setAudioFx({ _ = AudioFxEditing.setChorusEnabled(&$0, true) }, name: "x", clipId: "m")
        XCTAssertEqual(undoSteps(m), 3, "同じ状態は履歴に載せない")
        u.undo(); XCTAssertNil(m.clip("m")?.audioFx?.extended?.wah)
        u.undo(); XCTAssertNil(m.clip("m")?.audioFx?.extended?.lowPass)
        u.undo(); XCTAssertNil(m.clip("m")?.audioFx)
    }

    func testExtendedPanelInstantiates() {
        let m = makeModel()
        let panel = AudioFxExtendedPanel(model: m, clipId: "m", forceExpanded: true)
        _ = panel.body
        // エフェクトを付けた状態でも生成できる
        m.setAudioFx({ _ = AudioFxEditing.setRobotEnabled(&$0, true) }, name: "ロボット化の切り替え", clipId: "m")
        let panel2 = AudioFxExtendedPanel(model: m, clipId: "m", forceExpanded: true)
        _ = panel2.body
    }
}
