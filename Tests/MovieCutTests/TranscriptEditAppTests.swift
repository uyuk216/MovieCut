import XCTest
import MovieCutCore
@testable import MovieCut

/// 文字起こしで編集(アプリ側): 文の一覧 → 外した文を 1 回の Undo で取り除く、何も外さなければ何もしない、メニューの項目。
@MainActor
final class TranscriptEditAppTests: XCTestCase {
    private var fixturePath: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MovieCutCoreTests/Fixtures/aq_reimu.wav").path
    }

    /// 1.5 秒の音声クリップ(素材は 1.59 秒の実ファイル)と、その後ろに 1 秒のクリップ。
    private func makeModel() -> ProjectModel {
        let m = ProjectModel(project: Project.new())
        m.notices = OneTimeNotices()
        var c = Clip(); c.id = "snd"; c.type = .audio; c.start = 0; c.duration = 1.5; c.src = fixturePath
        var after = Clip(); after.id = "after"; after.type = .audio; after.start = 1.5; after.duration = 1; after.src = fixturePath
        var t = Track(name: "音"); t.clips = [c, after]
        m.project.tracks = [t]
        m.selectedClipId = "snd"
        return m
    }

    private let threeSentences: [TranscriptSegment] = [
        TranscriptSegment(text: "一文目。", start: 0, end: 0.5),
        TranscriptSegment(text: "二文目。", start: 0.5, end: 1.0),
        TranscriptSegment(text: "三文目。", start: 1.0, end: 1.4),
    ]

    func testScanThenRemoveMiddleSentenceIsOneUndoStepAndRipples() async throws {
        let m = makeModel()
        m.openTranscriptEditSheet()
        XCTAssertTrue(m.showTranscriptEditSheet)
        let found = try await m.scanTranscriptSentences(transcriber: TranscribeAppTests.StubTranscriber(threeSentences))
        XCTAssertEqual(found.map(\.text), ["一文目。", "二文目。", "三文目。"])
        let before = m.project.tracks[0].clips.map(\.duration).reduce(0, +)
        XCTAssertTrue(m.cutTranscriptSentences(clipId: "snd", removed: [found[1]], ripple: true))
        XCTAssertEqual(m.effectiveUndoManager.undoActionName, "文字起こしで編集")
        let after = m.project.tracks[0].clips.map(\.duration).reduce(0, +)
        XCTAssertEqual(after, before - 0.5, accuracy: 0.01, "二文目(0.5 秒)を取り除く")
        XCTAssertEqual(m.project.tracks[0].clips.last?.start ?? -1, 1.0, accuracy: 0.01, "後ろのクリップは詰まる")
        m.effectiveUndoManager.undo()
        XCTAssertEqual(m.project.tracks[0].clips.map(\.id), ["snd", "after"], "1 回の Undo で元に戻る")
        XCTAssertEqual(m.project.tracks[0].clips.map(\.duration), [1.5, 1])
    }

    func testNothingRemovedChangesNothingAndRegistersNoUndo() async throws {
        let m = makeModel()
        let before = m.project
        XCTAssertFalse(m.cutTranscriptSentences(clipId: "snd", removed: [], ripple: true))
        XCTAssertEqual(m.project, before)
        XCTAssertFalse(m.effectiveUndoManager.canUndo)
    }

    func testMenuItemIsInClipAudioSectionWithoutShortcut() {
        let m = makeModel()
        var s = MenuState(model: m)
        m.selectedClipId = "snd"
        s = MenuState(model: m)
        let item = AppMenuSpec.transcriptEditItem(s)
        XCTAssertEqual(item.title, "文字起こしで編集…")
        XCTAssertEqual(item.command, .transcriptEdit)
        XCTAssertNil(item.shortcut)
        XCTAssertTrue(item.enabled)
        XCTAssertFalse(AppMenuSpec.transcriptEditItem(MenuState(model: ProjectModel(project: Project.new()))).enabled, "クリップが無いときは出さない")
    }
}
