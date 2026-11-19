import XCTest
import SwiftUI
import MovieCutCore
@testable import MovieCut

/// VST3(W3-07/#67)のアプリ配線: スロット編集の Undo とインスペクタ節の生成。
/// 音声処理は未対応(検出のみ)なので、ここで確かめるのは「指定の保存と操作」だけ。
@MainActor
final class VST3AppTests: XCTestCase {
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

    func testVST3SlotEditsAreOneUndoStepEach() {
        let m = makeModel()
        let u = m.effectiveUndoManager
        // 重複追加・範囲外操作は履歴に載せない
        m.setAudioFx({ _ = AudioFxEditing.addVST3Slot(&$0, bundleID: "com.example.testverb", name: "TestVerb") },
                     name: ProjectModel.vst3UndoName, clipId: "m")
        XCTAssertEqual(m.clip("m")?.audioFx?.vst3Slots.first?.displayName, "TestVerb")
        m.setAudioFx({ _ = AudioFxEditing.addVST3Slot(&$0, bundleID: "com.example.testverb") },
                     name: ProjectModel.vst3UndoName, clipId: "m")
        m.setAudioFx({ _ = AudioFxEditing.setVST3SlotEnabled(&$0, at: 0, enabled: false) },
                     name: ProjectModel.vst3UndoName, clipId: "m")
        XCTAssertEqual(m.clip("m")?.audioFx?.enabledVST3Slots.count, 0)
        XCTAssertEqual(undoSteps(m), 2, "追加 1 + 無効化 1(重複追加は 0)")
        m.setAudioFx({ _ = AudioFxEditing.removeVST3Slot(&$0, at: 0) },
                     name: ProjectModel.vst3UndoName, clipId: "m")
        XCTAssertNil(m.clip("m")?.audioFx)
        XCTAssertEqual(undoSteps(m), 3)
        u.undo()
        XCTAssertEqual(m.clip("m")?.audioFx?.vst3Slots.count, 1, "削除は Undo で戻る")
    }

    func testVST3PanelInstantiates() {
        let m = makeModel()
        _ = VST3Panel(model: m, clipId: "m", forceExpanded: true).body
        m.setAudioFx({ _ = AudioFxEditing.addVST3Slot(&$0, bundleID: "com.example.testverb", name: "TestVerb") },
                     name: ProjectModel.vst3UndoName, clipId: "m")
        _ = VST3Panel(model: m, clipId: "m", forceExpanded: true).body
    }

    func testVST3AvailabilityNoteIsHonest() {
        // UI が参照する到達状態は「処理未対応・バイパス」であること(文言の単一の置き場は Core)
        XCTAssertFalse(VST3HostAvailability.current.canProcessAudio)
        XCTAssertTrue(VST3HostAvailability.current.userFacingNote.contains("未対応"))
    }
}
