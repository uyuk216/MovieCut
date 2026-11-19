import XCTest
import MovieCutCore
@testable import MovieCut

/// Paper Edit(アプリ側): 組み立てが 1 回の Undo で戻ること、元クリップを変えないこと、空の選択では何もしないこと。
@MainActor
final class PaperEditAppTests: XCTestCase {
    private var fixturePath: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MovieCutCoreTests/Fixtures/aq_reimu.wav").path
    }

    /// 1.5 秒の音声クリップ 1 本だけのプロジェクト。
    private func makeModel() -> ProjectModel {
        let m = ProjectModel(project: Project.new())
        m.notices = OneTimeNotices()
        var c = Clip(); c.id = "snd"; c.type = .audio; c.start = 0; c.duration = 1.5; c.src = fixturePath
        var t = Track(name: "音"); t.clips = [c]
        m.project.tracks = [t]
        m.selectedClipId = "snd"
        return m
    }

    private let sentences: [TranscriptSentence] = [
        TranscriptSentence(text: "一文目。", start: 0, end: 0.5),
        TranscriptSentence(text: "二文目。", start: 0.5, end: 1.0),
        TranscriptSentence(text: "三文目。", start: 1.0, end: 1.4),
    ]

    func testAssembleToTimelineIsOneUndoStepAndKeepsOriginal() {
        let m = makeModel()
        let original = m.project.tracks[0].clips[0]
        XCTAssertTrue(m.assemblePaperEdit(clipId: "snd", sentences: sentences, order: [2, 0],
                                          destination: .appendToTrack(0)))
        XCTAssertEqual(m.effectiveUndoManager.undoActionName, "ペーパーエディット")
        let clips = m.project.tracks[0].clips.sorted { $0.start < $1.start }
        XCTAssertEqual(clips.count, 3)
        XCTAssertEqual(clips.first { $0.id == "snd" }, original, "元クリップは変更しない")
        let made = clips.filter { $0.id != "snd" }
        XCTAssertEqual(made[0].start, 1.5, accuracy: 1e-9, "末尾から並ぶ")
        XCTAssertEqual(made[0].offset, 1.0, accuracy: 1e-9, "先頭は「三文目。」の区間")
        XCTAssertEqual(made[1].offset, 0, accuracy: 1e-9)
        m.effectiveUndoManager.undo()
        XCTAssertEqual(m.project.tracks[0].clips, [original], "1 回の Undo で元に戻る")
    }

    func testAssembleToNewSceneIsOneUndoStep() {
        let m = makeModel()
        XCTAssertTrue(m.assemblePaperEdit(clipId: "snd", sentences: sentences, order: [1],
                                          destination: .newScene(name: "ラフ")))
        XCTAssertEqual(m.project.scenes.count, 1)
        XCTAssertEqual(m.project.scenes[0].tracks[0].clips.count, 1)
        XCTAssertEqual(m.project.tracks[0].clips.count, 1, "タイムラインには足さない")
        m.effectiveUndoManager.undo()
        XCTAssertTrue(m.project.scenes.isEmpty, "1 回の Undo でシーンごと戻る")
    }

    func testEmptyOrderChangesNothingAndRegistersNoUndo() {
        let m = makeModel()
        let before = m.project
        XCTAssertFalse(m.assemblePaperEdit(clipId: "snd", sentences: sentences, order: [],
                                           destination: .appendToTrack(0)))
        XCTAssertEqual(m.project, before)
        XCTAssertFalse(m.effectiveUndoManager.canUndo)
    }
}
