import XCTest
import MovieCutCore
@testable import MovieCut

/// 音声の作り直しで尺が変わったとき、後ろのクリップをずらす設定(候補 31)。ずらしも元の編集と同じ 1 回の Undo。
@MainActor
final class VoiceRippleAppTests: XCTestCase {
    private var saved = false

    override func setUp() { saved = VoiceRippleSettings.enabled }
    override func tearDown() { VoiceRippleSettings.enabled = saved }

    private func model() -> ProjectModel {
        let m = ProjectModel(project: .new())
        let tone = ToneVoiceProvider(durations: [2.0], frequencies: [220])
        m.voiceProviderFactory = { _ in tone }
        let ch = m.project.characters[0]
        var clips: [Clip] = []
        for i in 0..<3 {
            var c = Clip(); c.id = "v\(i)"; c.type = .voice; c.charId = ch.id; c.text = "セリフ\(i)"
            c.src = "/nonexistent/v\(i).wav"; c.duration = 1.15; c.start = Double(i) * 3; c.subtitle = true
            clips.append(c)
        }
        m.project.tracks[0].clips = clips
        return m
    }

    private func undoAll(_ m: ProjectModel) -> Int {
        var n = 0
        while m.effectiveUndoManager.canUndo { m.effectiveUndoManager.undo(); n += 1 }
        return n
    }

    func testOffByDefaultLeavesFollowingClips() async {
        VoiceRippleSettings.enabled = false
        let m = model()
        let ok = await m.setVoiceText("新しいセリフ", clipId: "v0")
        XCTAssertTrue(ok)
        XCTAssertEqual(m.project.tracks[0].clips.map(\.start), [0, 3, 6])
    }

    func testOnShiftsFollowingClipsInOneUndo() async {
        VoiceRippleSettings.enabled = true
        let m = model()
        let before = m.project
        let ok = await m.setVoiceText("新しいセリフ", clipId: "v0")
        XCTAssertTrue(ok)
        XCTAssertEqual(m.clip("v0")!.duration, 2.15, accuracy: 0.002)
        XCTAssertEqual(m.project.tracks[0].clips.map(\.start)[1], 3 + 1.0, accuracy: 0.002)
        XCTAssertEqual(m.project.tracks[0].clips.map(\.start)[2], 6 + 1.0, accuracy: 0.002)
        XCTAssertTrue(m.statusText.contains("ずらしました"))
        XCTAssertEqual(undoAll(m), 1, "音声とずらしは 1 回の Undo")
        XCTAssertEqual(m.project, before)
    }

    func testRegenerateAllShiftsCumulatively() async {
        VoiceRippleSettings.enabled = true
        let m = model()
        let n = await m.regenerateAllVoices(charId: m.project.characters[0].id)
        XCTAssertEqual(n, 3)
        let s = m.project.tracks[0].clips.map(\.start)
        XCTAssertEqual(s[0], 0, accuracy: 1e-6)
        XCTAssertEqual(s[1], 4, accuracy: 0.003)
        XCTAssertEqual(s[2], 8, accuracy: 0.005)
        XCTAssertEqual(undoAll(m), 1)
    }

    func testMenuItemTogglesSetting() {
        VoiceRippleSettings.enabled = false
        var s = MenuState(); s.hasDocument = true
        let off = AppMenuSpec.clipLayerAndVoice(s).first { $0.command == .toggleVoiceRipple }
        XCTAssertEqual(off?.checked, false)
        XCTAssertNil(off?.shortcut)
        s.voiceRipple = true
        XCTAssertEqual(AppMenuSpec.clipLayerAndVoice(s).first { $0.command == .toggleVoiceRipple }?.checked, true)
        let m = ProjectModel(project: .new())
        AppMenu.perform(.toggleVoiceRipple, model: m)
        XCTAssertTrue(VoiceRippleSettings.enabled)
    }
}
