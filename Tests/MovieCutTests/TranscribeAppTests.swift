import XCTest
import MovieCutCore
@testable import MovieCut

/// 音声から字幕を作る(アプリ側): Undo は 1 回、何も無ければ何もしない、キャンセル、許可なしの表示、メニューの項目。
@MainActor
final class TranscribeAppTests: XCTestCase {
    /// 認識器の偽物(Core のテストと同じ役割。ここでは画面の流れだけ見る)。
    final class StubTranscriber: Transcriber, @unchecked Sendable {
        var segments: [TranscriptSegment]
        var error: Error?
        var waitUntilCancelled = false
        init(_ segments: [TranscriptSegment] = [], error: Error? = nil, waitUntilCancelled: Bool = false) {
            self.segments = segments; self.error = error; self.waitUntilCancelled = waitUntilCancelled
        }
        func transcribe(audioURL: URL, duration: Double, onProgress: @escaping @Sendable (Double) -> Void) async throws -> [TranscriptSegment] {
            if waitUntilCancelled { try await Task.sleep(nanoseconds: 10_000_000_000) }
            if let error { throw error }
            return segments
        }
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

    private func state(_ f: (inout MenuState) -> Void = { _ in }) -> MenuState {
        var s = MenuState(); s.hasDocument = true; f(&s); return s
    }

    func testTranscribeAddsSubtitleLayerAsOneUndoStep() async {
        let m = makeModel()
        let before = m.project
        let ok = await m.transcribeSelectedToSubtitles(transcriber: StubTranscriber([
            TranscriptSegment(text: "こんにちは", start: 0, end: 0.6),
            TranscriptSegment(text: "さようなら", start: 0.8, end: 1.4),
        ]))
        XCTAssertTrue(ok)
        XCTAssertNil(m.busyMessage, "終わったら処理中の表示を消す")
        XCTAssertNil(m.transcribeCancel)
        XCTAssertEqual(m.effectiveUndoManager.undoActionName, "音声から字幕を作る")
        XCTAssertEqual(undoSteps(m), 1)
        XCTAssertEqual(m.project.tracks.last?.name, "字幕")
        XCTAssertEqual(SubtitleFile.cues(from: m.project).map(\.text), ["こんにちは", "さようなら"])
        XCTAssertEqual(SubtitleFile.cues(from: m.project).first?.start ?? -1, 1, accuracy: 1e-9, "クリップの開始に合わせる")
        m.effectiveUndoManager.undo()
        XCTAssertEqual(m.project, before)
    }

    func testNoSegmentsChangesNothing() async {
        let m = makeModel()
        let before = m.project
        let ok = await m.transcribeSelectedToSubtitles(transcriber: StubTranscriber([]))
        XCTAssertFalse(ok)
        XCTAssertEqual(m.project, before)
        XCTAssertFalse(m.effectiveUndoManager.canUndo)
        XCTAssertEqual(m.statusText, "認識できた文字がありませんでした。字幕は作りませんでした")
    }

    func testNothingSelectedOrUnsupportedClipIsRefused() async {
        let m = makeModel()
        m.selectedClipId = nil
        let ok = await m.transcribeSelectedToSubtitles(transcriber: StubTranscriber([TranscriptSegment(text: "x", start: 0, end: 1)]))
        XCTAssertFalse(ok)
        XCTAssertFalse(m.effectiveUndoManager.canUndo)
        XCTAssertTrue(m.statusText.contains("音のあるクリップ"))
    }

    func testCancelFromOverlayLeavesProjectAndUndoAlone() async throws {
        let m = makeModel()
        let before = m.project
        let job = Task { await m.transcribeSelectedToSubtitles(transcriber: StubTranscriber([TranscriptSegment(text: "x", start: 0, end: 1)], waitUntilCancelled: true)) }
        // 処理中になり、取り消しが登録されるまで待つ
        for _ in 0..<500 where m.transcribeCancel == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        let cancel = try XCTUnwrap(m.transcribeCancel, "処理中はキャンセルできる")
        XCTAssertNotNil(m.busyMessage)
        cancel()
        let ok = await job.value
        XCTAssertFalse(ok)
        XCTAssertNil(m.busyMessage)
        XCTAssertEqual(m.project, before)
        XCTAssertFalse(m.effectiveUndoManager.canUndo)
        XCTAssertEqual(m.statusText, "音声の認識をキャンセルしました")
    }

    func testPermissionDeniedShowsJapaneseErrorAndNoUndo() async {
        let m = makeModel()
        let before = m.project
        let ok = await m.transcribeSelectedToSubtitles(transcriber: StubTranscriber(error: TranscriptionError.permissionDenied))
        XCTAssertFalse(ok)
        XCTAssertEqual(m.errorTitle, "音声から字幕を作れませんでした")
        XCTAssertTrue((m.errorMessage ?? "").contains("許可"))
        XCTAssertEqual(m.project, before)
        XCTAssertFalse(m.effectiveUndoManager.canUndo)
        XCTAssertNil(m.busyMessage)
    }

    func testMenuItemIsSpecTableAndEnabledOnlyForSupportedClip() {
        let on = AppMenuSpec.transcribeSubtitles(state { $0.canTranscribe = true })
        XCTAssertEqual(on.title, "音声から字幕を作る…")
        XCTAssertEqual(on.command, .transcribeSubtitles)
        XCTAssertNil(on.shortcut, "ショートカットは持たない")
        XCTAssertTrue(on.enabled)
        XCTAssertFalse(AppMenuSpec.transcribeSubtitles(state { _ in }).enabled)
        XCTAssertFalse(AppMenuSpec.transcribeSubtitles(state { $0.canTranscribe = true; $0.isLocked = true }).enabled)
        let all = AppMenuSpec.all(state { $0.canTranscribe = true })
        XCTAssertTrue(all.contains { $0.command == .transcribeSubtitles })
    }
}
