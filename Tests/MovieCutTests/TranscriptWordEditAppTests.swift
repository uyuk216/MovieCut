import XCTest
import MovieCutCore
@testable import MovieCut

/// 単語単位の編集(アプリ側): 単語の取り除きが 1 回の Undo で戻ること、単語の時刻が無い素材では
/// 何も変えず「文単位まで」を状態欄で明示すること。
@MainActor
final class TranscriptWordEditAppTests: XCTestCase {
    private var fixturePath: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MovieCutCoreTests/Fixtures/aq_reimu.wav").path
    }

    /// 1.5 秒の音声クリップと、その後ろに 1 秒のクリップ(TranscriptEditAppTests と同じ土台)。
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

    /// 単語の時刻つきの 1 文(単語 3 件: 0–0.5 / 0.5–1.0 / 1.0–1.4)。
    private let timedSentences: [TranscriptSentence] = [
        TranscriptSentence(text: "一文目。二文目。三文目。", start: 0, end: 1.4, words: [
            TranscriptSegment(text: "一文目。", start: 0, end: 0.5),
            TranscriptSegment(text: "二文目。", start: 0.5, end: 1.0),
            TranscriptSegment(text: "三文目。", start: 1.0, end: 1.4),
        ]),
    ]

    typealias Sel = TranscriptWordEdit.Selection

    func testRemoveMiddleWordIsOneUndoStepAndRipples() {
        let m = makeModel()
        let before = m.project.tracks[0].clips.map(\.duration).reduce(0, +)
        XCTAssertTrue(m.cutTranscriptWords(clipId: "snd", sentences: timedSentences,
                                           selections: [Sel(sentence: 0, word: 1)], ripple: true))
        XCTAssertEqual(m.effectiveUndoManager.undoActionName, "文字起こしで編集", "文の取り除きと同じ Undo 名")
        let afterTotal = m.project.tracks[0].clips.map(\.duration).reduce(0, +)
        XCTAssertEqual(afterTotal, before - 0.5, accuracy: 0.01, "二文目。(0.5 秒)を取り除く")
        XCTAssertEqual(m.project.tracks[0].clips.last?.start ?? -1, 1.0, accuracy: 0.01, "後ろのクリップは詰まる")
        m.effectiveUndoManager.undo()
        XCTAssertEqual(m.project.tracks[0].clips.map(\.id), ["snd", "after"], "1 回の Undo で元に戻る")
        XCTAssertEqual(m.project.tracks[0].clips.map(\.duration), [1.5, 1])
    }

    func testWordlessMaterialIsRefusedExplicitlyAndChangesNothing() {
        let m = makeModel()
        let wordless = [TranscriptSentence(text: "一文目。", start: 0, end: 0.5)]
        let before = m.project
        XCTAssertFalse(m.cutTranscriptWords(clipId: "snd", sentences: wordless,
                                            selections: [Sel(sentence: 0, word: 0)], ripple: true))
        XCTAssertEqual(m.project, before, "何も変えない")
        XCTAssertFalse(m.effectiveUndoManager.canUndo, "Undo は積まない")
        XCTAssertTrue(m.statusText.contains("文単位"), "状態欄で「文単位まで」を明示する: \(m.statusText)")
    }

    func testEmptySelectionChangesNothingAndRegistersNoUndo() {
        let m = makeModel()
        let before = m.project
        XCTAssertFalse(m.cutTranscriptWords(clipId: "snd", sentences: timedSentences, selections: [], ripple: true))
        XCTAssertEqual(m.project, before)
        XCTAssertFalse(m.effectiveUndoManager.canUndo)
    }
}
