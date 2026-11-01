import XCTest
import AVFoundation
@testable import MovieCutCore

/// 音声から字幕を作る(Core): 認識結果の時刻→タイムライン、文のまとめ、偽の認識器、失敗、キャンセル。
final class TranscriptionTests: XCTestCase {
    /// テスト用の認識器。受け取った音声ファイルを覚え、決めた結果を返す(または失敗・キャンセル待ち)。
    final class FakeTranscriber: Transcriber, @unchecked Sendable {
        var segments: [TranscriptSegment]
        var error: Error?
        var waitUntilCancelled = false
        private(set) var receivedURL: URL?
        private(set) var receivedBytes = -1
        private(set) var progress: [Double] = []

        init(_ segments: [TranscriptSegment] = [], error: Error? = nil, waitUntilCancelled: Bool = false) {
            self.segments = segments; self.error = error; self.waitUntilCancelled = waitUntilCancelled
        }

        func transcribe(audioURL: URL, duration: Double, onProgress: @escaping @Sendable (Double) -> Void) async throws -> [TranscriptSegment] {
            receivedURL = audioURL
            receivedBytes = (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? Int) ?? -1
            onProgress(0.5)
            progress.append(0.5)
            if waitUntilCancelled { try await Task.sleep(nanoseconds: 10_000_000_000) }
            if let error { throw error }
            return segments
        }
    }

    private func fixtureURL() throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: "aq_reimu", withExtension: "wav", subdirectory: "Fixtures"))
    }

    /// 頭が `start` 秒、長さ `duration` の音声クリップ(フィクスチャの音)。
    private func audioClip(start: Double = 2, duration: Double = 1, type: ClipType = .audio, src: String? = nil) throws -> Clip {
        var c = Clip()
        c.type = type
        c.start = start
        c.duration = duration
        c.src = try src ?? fixtureURL().path
        return c
    }

    private func project(with clip: Clip) -> Project {
        var p = Project.new()
        var t = Track(name: "音")
        t.clips = [clip]
        p.tracks = [t]
        return p
    }

    // MARK: 認識結果 → タイムライン

    func testCuesMapToTimelineAndClipRange() throws {
        // クリップは 10 秒から 5 秒間。認識の時刻はクリップの頭から。はみ出しは切る。
        var c = try audioClip(start: 10, duration: 5)
        c.offset = 0
        let segs = [
            TranscriptSegment(text: "こんにちは", start: 0, end: 1.5),
            TranscriptSegment(text: "元気です", start: 2, end: 4),
            TranscriptSegment(text: "はみ出し", start: 4.5, end: 7),
            TranscriptSegment(text: "全部外", start: 6, end: 7),
        ]
        let cues = TranscriptSubtitles.cues(from: segs, clip: c)
        XCTAssertEqual(cues, [
            SubtitleCue(start: 10, end: 11.5, text: "こんにちは"),
            SubtitleCue(start: 12, end: 14, text: "元気です"),
            SubtitleCue(start: 14.5, end: 15, text: "はみ出し"),
        ])
    }

    func testCuesDropEmptyBodiesAndCleanNewlines() throws {
        let c = try audioClip(start: 0, duration: 10)
        let segs = [
            TranscriptSegment(text: "   \n ", start: 0, end: 1),
            TranscriptSegment(text: "あ\n\nい", start: 1, end: 2),
            TranscriptSegment(text: "ゼロ長", start: 3, end: 3),
            TranscriptSegment(text: "逆転", start: 5, end: 4),
            TranscriptSegment(text: "無限", start: .infinity, end: 6),
        ]
        let cues = TranscriptSubtitles.cues(from: segs, clip: c)
        XCTAssertEqual(cues, [SubtitleCue(start: 1, end: 2, text: "あ\nい")])
    }

    func testCuesAreSortedByStartKeepingOrderForTies() throws {
        let c = try audioClip(start: 0, duration: 10)
        let segs = [
            TranscriptSegment(text: "後", start: 5, end: 6),
            TranscriptSegment(text: "先1", start: 1, end: 2),
            TranscriptSegment(text: "先2", start: 1, end: 3),
        ]
        XCTAssertEqual(TranscriptSubtitles.cues(from: segs, clip: c).map(\.text), ["先1", "先2", "後"])
    }

    // MARK: 文のまとめ

    func testPhrasesBreakOnLongGapSentenceEndAndLength() {
        let words = [
            TranscriptSegment(text: "あ", start: 0, end: 0.2),
            TranscriptSegment(text: "い", start: 0.2, end: 0.4),
            TranscriptSegment(text: "う", start: 2.0, end: 2.2),        // 間が maxGap を超える
            TranscriptSegment(text: "え。", start: 2.2, end: 2.4),       // 文末の記号で切る
            TranscriptSegment(text: "お", start: 2.5, end: 2.7),
        ]
        let p = TranscriptGrouping.phrases(from: words)
        XCTAssertEqual(p.map(\.text), ["あい", "うえ。", "お"], "間が空いた所と文末で切る")
        XCTAssertEqual(p[0].start, 0); XCTAssertEqual(p[0].end, 0.4, accuracy: 1e-9)
        XCTAssertEqual(p[1].start, 2.0)
    }

    func testPhrasesBreakWhenTooLong() {
        let long = String(repeating: "あ", count: TranscriptGrouping.maxChars)
        let words = [TranscriptSegment(text: long, start: 0, end: 1), TranscriptSegment(text: "い", start: 1, end: 1.2)]
        XCTAssertEqual(TranscriptGrouping.phrases(from: words).map(\.text), [long, "い"])
    }

    func testPhrasesJoinLatinWordsWithSpaceAndDropBlanks() {
        let words = [
            TranscriptSegment(text: "Hello", start: 0, end: 0.3),
            TranscriptSegment(text: " ", start: 0.3, end: 0.3),
            TranscriptSegment(text: "world", start: 0.3, end: 0.6),
            TranscriptSegment(text: "まで", start: 0.6, end: 0.9),
        ]
        XCTAssertEqual(TranscriptGrouping.phrases(from: words).map(\.text), ["Hello worldまで"], "英数字どうしだけ空白を入れる")
    }

    // MARK: 対象のクリップ

    func testSupportsOnlySoundClipsWithoutSpeedChange() throws {
        XCTAssertTrue(TranscriptionSupport.supports(try audioClip(type: .audio)))
        XCTAssertTrue(TranscriptionSupport.supports(try audioClip(type: .video)))
        XCTAssertFalse(TranscriptionSupport.supports(try audioClip(type: .image)))
        XCTAssertFalse(TranscriptionSupport.supports(try audioClip(type: .text)))
        var fast = try audioClip(type: .audio)
        fast.speed = 2
        XCTAssertFalse(TranscriptionSupport.supports(fast), "速度を変えたクリップは時刻が 1 対 1 にならない")
        var rev = try audioClip(type: .video)
        rev.reverse = true
        XCTAssertFalse(TranscriptionSupport.supports(rev))
    }

    // MARK: 実行(偽の認識器)

    func testWriteWAVIsMonoAndRightLength() throws {
        let c = try audioClip(start: 0, duration: 1)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tr-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try TranscriptionAudio.writeWAV(clip: c, to: url)
        let f = try AVAudioFile(forReading: url)
        XCTAssertEqual(f.fileFormat.channelCount, 1)
        XCTAssertEqual(f.fileFormat.sampleRate, AudioMixer.sampleRate, accuracy: 0.5)
        XCTAssertEqual(Double(f.length) / f.fileFormat.sampleRate, 1, accuracy: 0.01)
    }

    func testRunMapsSegmentsIntoSubtitleLayerWithStyle() async throws {
        let clip = try audioClip(start: 2, duration: 1)
        let p = project(with: clip)
        let look = try XCTUnwrap(TextStyleLibrary.builtins.first { $0.id == "builtin.classic" }?.look)
        let fake = FakeTranscriber([TranscriptSegment(text: "こんにちは", start: 0.1, end: 0.8),
                                    TranscriptSegment(text: "元気です", start: 0.9, end: 1.5)])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tr-dir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let r = try await SubtitleTranscription.run(clip: clip, project: p, transcriber: fake, style: look, tempDirectory: dir)
        let made = try XCTUnwrap(r)
        XCTAssertEqual(made.count, 2)
        XCTAssertGreaterThan(fake.receivedBytes, 44, "認識器には音声の WAV が渡る")
        XCTAssertEqual(fake.progress, [0.5])
        XCTAssertEqual(made.project.tracks.last?.name, SubtitleFile.layerName)
        XCTAssertEqual(SubtitleFile.cues(from: made.project), [
            SubtitleCue(start: 2.1, end: 2.8, text: "こんにちは"),
            SubtitleCue(start: 2.9, end: 3, text: "元気です"),
        ])
        var expected = Clip()
        expected.type = .text
        look.apply(to: &expected)
        let added = try XCTUnwrap(made.project.tracks.last?.clips.first)
        XCTAssertEqual(added.textStyle, expected.textStyle, "字幕の自動生成と同じ見た目")
        XCTAssertEqual(added.color, expected.color)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [], "一時ファイルは終わったら消す")
    }

    func testRunWithNoSegmentsReturnsNil() async throws {
        let clip = try audioClip()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tr-dir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try await SubtitleTranscription.run(clip: clip, project: project(with: clip), transcriber: FakeTranscriber([]), style: nil, tempDirectory: dir)
        XCTAssertNil(r, "認識できる文が無ければ何も作らない")
    }

    func testRunPassesThroughPermissionErrorAndCleansUp() async throws {
        let clip = try audioClip()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tr-dir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            _ = try await SubtitleTranscription.run(clip: clip, project: project(with: clip), transcriber: FakeTranscriber(error: TranscriptionError.permissionDenied), style: nil, tempDirectory: dir)
            XCTFail("許可がなければ失敗する")
        } catch {
            XCTAssertEqual(error as? TranscriptionError, .permissionDenied)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
    }

    func testRunCancelStopsWithCancellationAndCleansUp() async throws {
        let clip = try audioClip()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tr-dir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = FakeTranscriber([TranscriptSegment(text: "x", start: 0, end: 1)], waitUntilCancelled: true)
        let p = project(with: clip)
        let job = Task { try await SubtitleTranscription.run(clip: clip, project: p, transcriber: fake, style: nil, tempDirectory: dir) }
        try await Task.sleep(nanoseconds: 300_000_000)
        job.cancel()
        do {
            _ = try await job.value
            XCTFail("キャンセルされたら結果を返さない")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
    }

    func testRunWithClipWithoutAudioThrowsNoAudio() async throws {
        let clip = try audioClip(src: "/nonexistent/moviecut-no-such-file.wav")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tr-dir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            _ = try await SubtitleTranscription.run(clip: clip, project: project(with: clip), transcriber: FakeTranscriber([]), style: nil, tempDirectory: dir)
            XCTFail("音が無ければ失敗する")
        } catch {
            XCTAssertEqual(error as? TranscriptionError, .noAudio)
        }
    }

    func testEveryTranscriptionErrorHasJapaneseMessage() {
        let all: [TranscriptionError] = [.permissionDenied, .permissionNotChecked, .permissionRestricted, .unsupportedLocale, .unavailable, .onDeviceUnavailable, .noAudio, .failed("x")]
        for e in all {
            let msg = e.errorDescription ?? ""
            XCTAssertFalse(msg.isEmpty)
            XCTAssertTrue(msg.contains { $0.unicodeScalars.contains { (0x3040...0x9FFF).contains($0.value) } }, "日本語で出す: \(msg)")
        }
    }
}
