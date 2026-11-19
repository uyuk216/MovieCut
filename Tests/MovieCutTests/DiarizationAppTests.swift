import XCTest
import MovieCutCore
@testable import MovieCut

/// 話者分離(W3-27 / 監査 #75)のアプリ側: 実行 → 字幕作成(Undo 1 回)、
/// 既存字幕へのラベル付与(Undo 1 回)、台本欄への送信(Undo 1 回)、シート開閉の条件。
/// 認識器は偽物、音声は Core テストのフィクスチャを使う。方式は音響特徴による簡易判定。
@MainActor
final class DiarizationAppTests: XCTestCase {
    final class StubTranscriber: Transcriber, @unchecked Sendable {
        var segments: [TranscriptSegment]
        init(_ segments: [TranscriptSegment]) { self.segments = segments }
        func transcribe(audioURL: URL, duration: Double, onProgress: @escaping @Sendable (Double) -> Void) async throws -> [TranscriptSegment] { segments }
    }

    private var fixturePath: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MovieCutCoreTests/Fixtures/aq_reimu.wav").path
    }

    private func makeModel() -> ProjectModel {
        let m = ProjectModel(project: Project.new())
        m.notices = OneTimeNotices()
        var c = Clip()
        c.id = "snd"
        c.type = .audio
        c.start = 1
        c.duration = 1.5
        c.src = fixturePath
        var t = Track(name: "音")
        t.clips = [c]
        m.project.tracks = [t]
        m.selectedClipId = "snd"
        return m
    }

    private func undoSteps(_ m: ProjectModel) -> Int {
        let u = m.effectiveUndoManager
        var n = 0
        while u.canUndo { u.undo(); n += 1 }
        for _ in 0..<n { u.redo() }
        return n
    }

    private let twoSegments = [
        TranscriptSegment(text: "こんにちは", start: 0, end: 0.6),
        TranscriptSegment(text: "さようなら", start: 0.8, end: 1.4),
    ]

    func testOpenSheetRequiresTranscribableSelection() {
        let m = makeModel()
        m.openDiarizationSheet()
        XCTAssertTrue(m.showDiarizationSheet)
        XCTAssertEqual(m.diarizationClipId, "snd")
        let empty = ProjectModel(project: .new())
        empty.openDiarizationSheet()
        XCTAssertFalse(empty.showDiarizationSheet)
    }

    func testRunThenApplyToSubtitlesIsOneUndo() async throws {
        let m = makeModel()
        m.openDiarizationSheet()
        let before = m.project
        let run = try await m.runDiarization(transcriber: StubTranscriber(twoSegments))
        XCTAssertEqual(run.diarized.count, 2)
        XCTAssertEqual(run.features.count, 2)
        XCTAssertTrue(m.applyDiarizationToSubtitles(run.diarized))
        XCTAssertEqual(m.effectiveUndoManager.undoActionName, ProjectModel.diarizationSubtitleUndoName)
        XCTAssertEqual(undoSteps(m), 1)
        let texts = SubtitleFile.cues(from: m.project).map(\.text)
        XCTAssertEqual(texts.count, 2)
        XCTAssertTrue(texts.allSatisfy { DiarizationText.hasSpeakerPrefix($0) }, "字幕に話者ラベルが付く: \(texts)")
        XCTAssertTrue(texts[0].contains("こんにちは"))
        XCTAssertTrue(texts[1].contains("さようなら"))
        m.effectiveUndoManager.undo()
        XCTAssertEqual(m.project, before)
    }

    func testApplyLabelsToExistingSubtitlesIsOneUndo() async throws {
        let m = makeModel()
        // 先に通常の文字起こしで字幕を作っておく
        let ok = await m.transcribeSelectedToSubtitles(transcriber: StubTranscriber(twoSegments))
        XCTAssertTrue(ok)
        XCTAssertEqual(SubtitleFile.cues(from: m.project).map(\.text), ["こんにちは", "さようなら"])
        m.openDiarizationSheet()
        let diarized = [
            DiarizedSegment(segment: twoSegments[0], speaker: 0),
            DiarizedSegment(segment: twoSegments[1], speaker: 1),
        ]
        let stepsBefore = undoSteps(m)
        let n = m.applyDiarizationLabelsToExistingSubtitles(diarized)
        XCTAssertEqual(n, 2)
        XCTAssertEqual(undoSteps(m), stepsBefore + 1, "ラベル付与は Undo 1 回")
        XCTAssertEqual(SubtitleFile.cues(from: m.project).map(\.text), ["話者1：こんにちは", "話者2：さようなら"])
        m.effectiveUndoManager.undo()
        XCTAssertEqual(SubtitleFile.cues(from: m.project).map(\.text), ["こんにちは", "さようなら"])
    }

    func testSendToScriptIsOneUndo() {
        let m = makeModel()
        m.openDiarizationSheet()
        let diarized = [
            DiarizedSegment(segment: twoSegments[0], speaker: 0),
            DiarizedSegment(segment: twoSegments[1], speaker: 1),
        ]
        let n = m.sendDiarizationToScript(diarized)
        XCTAssertEqual(n, 2)
        XCTAssertEqual(m.scriptText, "話者1: こんにちは\n話者2: さようなら")
        m.effectiveUndoManager.undo()
        XCTAssertEqual(m.scriptText, "")
        m.effectiveUndoManager.redo()
        XCTAssertEqual(m.scriptText, "話者1: こんにちは\n話者2: さようなら")
    }

    func testApplyWithNoSegmentsChangesNothing() {
        let m = makeModel()
        m.openDiarizationSheet()
        let before = m.project
        XCTAssertFalse(m.applyDiarizationToSubtitles([]))
        XCTAssertEqual(m.project, before)
        XCTAssertEqual(m.applyDiarizationLabelsToExistingSubtitles([]), 0)
        XCTAssertEqual(m.project, before)
    }
}
