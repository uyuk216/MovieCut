import XCTest
import MovieCutCore
@testable import MovieCut

/// 文字起こしを書き出す(アプリ側): txt / srt の中身、字幕レイヤーへの追加(Undo 1 回)、空結果のときファイルを作らないこと、メニューの項目。
@MainActor
final class TranscriptExportAppTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-export-app-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private var fixturePath: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MovieCutCoreTests/Fixtures/aq_reimu.wav").path
    }

    /// 開始 1 秒・長さ 1.5 秒の音のクリップを選んだ状態のプロジェクト。
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

    private var twoSegments: [TranscriptSegment] {
        [TranscriptSegment(text: "こんにちは", start: 0, end: 0.6),
         TranscriptSegment(text: "さようなら", start: 0.8, end: 1.4)]
    }

    func testTxtFileHasTheRecognizedTextOnly() async throws {
        let m = makeModel()
        let url = tmp.appendingPathComponent("out.txt")
        let ok = await m.exportTranscriptOfSelectedClip(transcriber: TranscribeAppTests.StubTranscriber(twoSegments), to: url,
                                                        format: .txt, addToTimeline: false)
        XCTAssertTrue(ok)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "こんにちは\nさようなら\n")
        XCTAssertFalse(m.project.tracks.contains { $0.name == "字幕" }, "addToTimeline が false なら字幕レイヤーは作らない")
        XCTAssertFalse(m.effectiveUndoManager.canUndo)
        XCTAssertNil(m.busyMessage)
        XCTAssertNil(m.transcribeCancel)
    }

    func testMixedJapaneseEnglishIsKeptAsRecognized() async throws {
        let m = makeModel()
        let url = tmp.appendingPathComponent("mixed.txt")
        let ok = await m.exportTranscriptOfSelectedClip(transcriber: TranscribeAppTests.StubTranscriber([
            TranscriptSegment(text: "今日は Meeting をします。次は Deploy です", start: 0, end: 1),
        ]), to: url, format: .txt, addToTimeline: false)
        XCTAssertTrue(ok)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "今日は Meeting をします。次は Deploy です\n")
    }

    func testSrtFileHasNumbersAndTimestampsOnClipTimeline() async throws {
        let m = makeModel()
        let url = tmp.appendingPathComponent("out.srt")
        let ok = await m.exportTranscriptOfSelectedClip(transcriber: TranscribeAppTests.StubTranscriber(twoSegments), to: url,
                                                        format: .srt, addToTimeline: false)
        XCTAssertTrue(ok)
        let body = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(body.hasPrefix("1\n"), body)
        XCTAssertTrue(body.contains("00:00:01,000 --> 00:00:01,600"), body)
        XCTAssertTrue(body.contains("2\n"), body)
        XCTAssertTrue(body.contains("00:00:01,800 --> 00:00:02,400"), body)
        XCTAssertTrue(body.contains("こんにちは"))
        XCTAssertTrue(body.contains("さようなら"))
    }

    func testAddToTimelineAddsSubtitleLayerAsOneUndoStep() async throws {
        let m = makeModel()
        let url = tmp.appendingPathComponent("both.txt")
        let ok = await m.exportTranscriptOfSelectedClip(transcriber: TranscribeAppTests.StubTranscriber(twoSegments), to: url,
                                                        format: .txt, addToTimeline: true)
        XCTAssertTrue(ok)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "こんにちは\nさようなら\n")
        XCTAssertEqual(m.effectiveUndoManager.undoActionName, "文字起こしを書き出す")
        XCTAssertEqual(m.project.tracks.last?.name, "字幕")
        XCTAssertEqual(SubtitleFile.cues(from: m.project).map(\.text), ["こんにちは", "さようなら"])
        XCTAssertEqual(SubtitleFile.cues(from: m.project).first?.start ?? -1, 1, accuracy: 1e-9, "クリップの開始に合わせる")
        XCTAssertEqual(undoSteps(m), 1, "Undo は 1 回で戻る")
    }

    func testEmptyRecognitionWritesNoFile() async {
        let m = makeModel()
        let before = m.project
        let url = tmp.appendingPathComponent("empty.txt")
        let ok = await m.exportTranscriptOfSelectedClip(transcriber: TranscribeAppTests.StubTranscriber([]), to: url,
                                                        format: .txt, addToTimeline: true)
        XCTAssertFalse(ok)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "認識結果が空ならファイルは作らない")
        XCTAssertEqual(m.project, before)
        XCTAssertFalse(m.effectiveUndoManager.canUndo)
        XCTAssertEqual(m.statusText, "認識できた文字がありませんでした。ファイルは作りませんでした")
    }

    func testRecognitionFailureShowsErrorAndWritesNoFile() async {
        let m = makeModel()
        let url = tmp.appendingPathComponent("fail.txt")
        let ok = await m.exportTranscriptOfSelectedClip(transcriber: TranscribeAppTests.StubTranscriber(error: TranscriptionError.permissionDenied),
                                                        to: url, format: .txt, addToTimeline: false)
        XCTAssertFalse(ok)
        XCTAssertEqual(m.errorTitle, "文字起こしを書き出せませんでした")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testNothingSelectedIsRefused() async {
        let m = makeModel()
        m.selectedClipId = nil
        let url = tmp.appendingPathComponent("none.txt")
        let ok = await m.exportTranscriptOfSelectedClip(transcriber: TranscribeAppTests.StubTranscriber(twoSegments), to: url,
                                                        format: .txt, addToTimeline: true)
        XCTAssertFalse(ok)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(m.statusText.contains("音のあるクリップ"))
    }

    func testExportMenuItemSpecs() {
        let on = AppMenuSpec.transcribeExport(state { $0.canTranscribe = true })
        XCTAssertEqual(on.title, "文字起こしを書き出す…")
        XCTAssertEqual(on.command, .transcribeExport)
        XCTAssertNil(on.shortcut, "ショートカットは持たない")
        XCTAssertTrue(on.enabled)
        XCTAssertFalse(AppMenuSpec.transcribeExport(state { _ in }).enabled)
        XCTAssertFalse(AppMenuSpec.transcribeExport(state { $0.canTranscribe = true; $0.isLocked = true }).enabled)

        let whisper = AppMenuSpec.transcribeExportWhisper(state { $0.canTranscribe = true })
        XCTAssertEqual(whisper.title, "文字起こしを書き出す（Whisper）…")
        XCTAssertEqual(whisper.command, .transcribeExportWhisper)
        XCTAssertNil(whisper.shortcut)
        XCTAssertTrue(whisper.enabled)
        XCTAssertFalse(AppMenuSpec.transcribeExportWhisper(state { _ in }).enabled)

        let all = AppMenuSpec.all(state { $0.canTranscribe = true })
        XCTAssertTrue(all.contains { $0.command == .transcribeExport })
        XCTAssertTrue(all.contains { $0.command == .transcribeExportWhisper })
    }
}
