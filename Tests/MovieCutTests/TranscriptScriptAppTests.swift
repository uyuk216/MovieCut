import XCTest
import MovieCutCore
@testable import MovieCut

/// 台本の双方向編集(アプリ側): 操作 1 回 = Undo 1 回、タイムライン側の Undo / 操作が台本の状態に追随すること。
@MainActor
final class TranscriptScriptAppTests: XCTestCase {
    private let sentences: [TranscriptSentence] = [
        TranscriptSentence(text: "一文目。", start: 0, end: 0.5),
        TranscriptSentence(text: "二文目。", start: 0.6, end: 1.0),
        TranscriptSentence(text: "三文目。", start: 1.2, end: 1.9),
    ]

    private func makeModel() -> ProjectModel {
        let m = ProjectModel(project: Project.new())
        m.notices = OneTimeNotices()
        var c = Clip(); c.id = "snd"; c.type = .audio; c.start = 0; c.duration = 2; c.src = "/tmp/a.wav"
        var t = Track(name: "音"); t.clips = [c]
        m.project.tracks = [t]
        return m
    }

    private func coverages(_ m: ProjectModel) -> [TranscriptScripting.Coverage] {
        TranscriptScripting.rows(of: m.project.transcriptScripts[0], in: m.project).map(\.coverage)
    }

    func testEachBidirectionalEditIsOneUndoStep() {
        let m = makeModel()
        XCTAssertTrue(m.linkTranscriptScript(clipId: "snd", sentences: sentences))
        XCTAssertEqual(m.effectiveUndoManager.undoActionName, "台本で編集")
        let linkedProject = m.project
        let sc = m.project.transcriptScripts[0]

        // 削除 → Undo 1 回で元に戻る(台本の状態もクリップも)
        XCTAssertTrue(m.deleteScriptSentence(scriptId: sc.id, sentenceId: sc.sentences[1].id))
        XCTAssertEqual(coverages(m), [.linked, .unlinked, .linked])
        XCTAssertEqual(m.project.tracks[0].clips.count, 2)
        m.effectiveUndoManager.undo()
        XCTAssertEqual(m.project, linkedProject)

        // 並べ替え → Undo 1 回
        XCTAssertTrue(m.reorderScriptSentences(scriptId: sc.id, fromOffsets: IndexSet(integer: 2), toOffset: 0))
        XCTAssertNotEqual(m.project.tracks, linkedProject.tracks)
        m.effectiveUndoManager.undo()
        XCTAssertEqual(m.project, linkedProject)

        // 連動そのものも 1 回で元に戻る(分割も台本も消える)
        m.effectiveUndoManager.undo()
        XCTAssertEqual(m.project.tracks[0].clips.count, 1)
        XCTAssertTrue(m.project.transcriptScripts.isEmpty)
    }

    func testTimelineEditsAndUndoFollowTheScriptState() {
        let m = makeModel()
        m.linkTranscriptScript(clipId: "snd", sentences: sentences)
        let ids = m.project.tracks[0].clips.map(\.id)
        // タイムライン側でクリップを削除すると、台本の同じ文が「対応なし」になる
        _ = m.edit("削除") { p in p = ClipEditing.delete(in: p, clipId: ids[2])! }
        XCTAssertEqual(coverages(m), [.linked, .linked, .unlinked])
        m.effectiveUndoManager.undo()
        XCTAssertEqual(coverages(m), [.linked, .linked, .linked])
    }

    func testRetextIsOneUndoAndLeavesTimelineAlone() {
        let m = makeModel()
        m.linkTranscriptScript(clipId: "snd", sentences: sentences)
        let sc = m.project.transcriptScripts[0]
        let before = m.project.tracks
        XCTAssertTrue(m.retextScriptSentence(scriptId: sc.id, sentenceId: sc.sentences[0].id, text: "直した文。"))
        XCTAssertEqual(m.project.transcriptScripts[0].sentences[0].text, "直した文。")
        XCTAssertEqual(m.project.tracks, before)
        m.effectiveUndoManager.undo()
        XCTAssertEqual(m.project.transcriptScripts[0].sentences[0].text, "一文目。")
    }

    func testUnsupportedClipIsRefusedWithStatus() {
        let m = makeModel()
        m.project.tracks[0].clips[0].speed = 2
        XCTAssertFalse(m.linkTranscriptScript(clipId: "snd", sentences: sentences))
        XCTAssertTrue(m.statusText.contains("速度変更"))
        XCTAssertTrue(m.project.transcriptScripts.isEmpty)
    }
}
