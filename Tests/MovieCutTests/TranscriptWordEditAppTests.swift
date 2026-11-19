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

    // MARK: 単語の組み立て(Paper Edit の単語版)

    func testAssembleWordsIsOneUndoStepAndKeepsOriginal() {
        let m = makeModel()
        let original = m.project.tracks[0].clips[0]
        // 三文目。(1.0–1.4) → 一文目。(0–0.5) の順で組み立てる
        XCTAssertTrue(m.assemblePaperEditWords(clipId: "snd", sentences: timedSentences,
                                               order: [Sel(sentence: 0, word: 2), Sel(sentence: 0, word: 0)],
                                               destination: .appendToTrack(0)))
        XCTAssertEqual(m.effectiveUndoManager.undoActionName, "ペーパーエディット", "文の組み立てと同じ Undo 名")
        let clips = m.project.tracks[0].clips.sorted { $0.start < $1.start }
        XCTAssertEqual(clips.count, 4)
        XCTAssertEqual(clips.first { $0.id == "snd" }, original, "元クリップは変更しない")
        let made = clips.filter { $0.id != "snd" && $0.id != "after" }
        XCTAssertEqual(made.count, 2)
        XCTAssertEqual(made[0].start, 2.5, accuracy: 1e-9, "レイヤーの末尾(2.5 秒)から並ぶ")
        XCTAssertEqual(made[0].offset, 1.0, accuracy: 1e-9, "先頭は「三文目。」の区間")
        XCTAssertEqual(made[0].duration, 0.4, accuracy: 1e-9)
        XCTAssertEqual(made[1].offset, 0, accuracy: 1e-9, "次は「一文目。」の区間")
        XCTAssertEqual(made[1].start, 2.9, accuracy: 1e-9, "隙間なく続く")
        m.effectiveUndoManager.undo()
        XCTAssertEqual(m.project.tracks[0].clips.map(\.id), ["snd", "after"], "1 回の Undo で元に戻る")
    }

    func testAssembleWordsWithWordlessSelectionChangesNothing() {
        let m = makeModel()
        let wordless = [TranscriptSentence(text: "一文目。", start: 0, end: 0.5)]
        let before = m.project
        XCTAssertFalse(m.assemblePaperEditWords(clipId: "snd", sentences: wordless,
                                                order: [Sel(sentence: 0, word: 0)],
                                                destination: .appendToTrack(0)))
        XCTAssertEqual(m.project, before, "何も変えない")
        XCTAssertFalse(m.effectiveUndoManager.canUndo, "Undo は積まない")
        XCTAssertTrue(m.statusText.contains("単語単位の時刻が無い"), "状態欄で理由を明示する: \(m.statusText)")
    }

    func testEmptySelectionChangesNothingAndRegistersNoUndo() {
        let m = makeModel()
        let before = m.project
        XCTAssertFalse(m.cutTranscriptWords(clipId: "snd", sentences: timedSentences, selections: [], ripple: true))
        XCTAssertEqual(m.project, before)
        XCTAssertFalse(m.effectiveUndoManager.canUndo)
    }
}
