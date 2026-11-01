import XCTest
@testable import MovieCutCore

/// 文字起こしでテキスト編集(Core): 文の組み立て・認識(偽物)・外した文の取り除き(無音カットの経路・ripple)。
final class TranscriptEditTests: XCTestCase {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-edit-\(UUID().uuidString)")
    override func setUpWithError() throws { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    /// 認識器の偽物: 与えた単語を返し、受け取った音声ファイルがあったかを記録する。
    final class FakeTranscriber: Transcriber, @unchecked Sendable {
        var words: [TranscriptSegment]
        private(set) var receivedURL: URL?
        private(set) var existedWhenCalled = false
        init(_ words: [TranscriptSegment]) { self.words = words }
        func transcribe(audioURL: URL, duration: Double, onProgress: @escaping @Sendable (Double) -> Void) async throws -> [TranscriptSegment] {
            receivedURL = audioURL
            existedWhenCalled = FileManager.default.fileExists(atPath: audioURL.path)
            return words
        }
    }

    func audioClip(id: String, start: Double, duration: Double, src: String = "/x.wav") -> Clip {
        var c = Clip(); c.id = id; c.type = .audio; c.start = start; c.duration = duration; c.src = src
        return c
    }

    func seg(_ text: String, _ a: Double, _ b: Double) -> TranscriptSegment { TranscriptSegment(text: text, start: a, end: b) }

    // MARK: 文の組み立て

    func testSentencesFollowSubtitleGroupingAndStayInsideTheClip() {
        let clip = audioClip(id: "a", start: 10, duration: 3)
        // 句点で切る / 空の単語は捨てる / 無音 0.8 秒超で切る / 末尾をまたぐ文は長さで切る / 長さの外だけの単語は捨てる
        let words = [seg("おはよう。", 0, 0.8), seg("今日は", 1.0, 1.4), seg("晴れ", 1.4, 1.8), seg("", 1.9, 2.0),
                     seg("末尾", 2.8, 3.6), seg("外", 5.0, 5.5)]
        let s = TranscriptTextEdit.sentences(from: words, clip: clip)
        XCTAssertEqual(s.map(\.text), ["おはよう。", "今日は晴れ", "末尾"])
        XCTAssertEqual(s[1].start, 1.0, accuracy: 1e-9)
        XCTAssertEqual(s[2].start, 2.8, accuracy: 1e-9)
        XCTAssertEqual(s[2].end, 3, accuracy: 1e-9, "クリップの長さの外へは出さない")
    }

    func testNoSentenceWhenClipHasNoLength() {
        XCTAssertTrue(TranscriptTextEdit.sentences(from: [seg("あ", 0, 1)], clip: audioClip(id: "a", start: 0, duration: 0)).isEmpty)
    }

    // MARK: 認識(偽物)

    func testRunReturnsSentencesAndRemovesItsTemporaryAudio() async throws {
        let sine = tmp.appendingPathComponent("s.wav")
        try AudioFixture.writeSine(sine, sampleRate: 24000, segments: [(3, 0.3)])
        let clip = audioClip(id: "a", start: 0, duration: 3, src: sine.path)
        let fake = FakeTranscriber([seg("一文目。", 0, 1), seg("二文目。", 1, 2)])
        let s = try await TranscriptTextEdit.run(clip: clip, transcriber: fake, tempDirectory: tmp)
        XCTAssertEqual(s.map(\.text), ["一文目。", "二文目。"])
        XCTAssertTrue(fake.existedWhenCalled, "認識器には音声ファイルが渡る")
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(fake.receivedURL).path), "一時ファイルは終わったら消す")
    }

    func testRunOnNonAudioClipReturnsEmptyWithoutCallingTranscriber() async throws {
        var t = Clip(); t.type = .text; t.duration = 2
        let fake = FakeTranscriber([seg("あ", 0, 1)])
        let s = try await TranscriptTextEdit.run(clip: t, transcriber: fake, tempDirectory: tmp)
        XCTAssertTrue(s.isEmpty)
        XCTAssertNil(fake.receivedURL)
    }

    // MARK: 取り除く(無音カットの経路)

    func testRemovingMiddleSentenceRipplesTheRestAndKeepsLaterClipsAligned() throws {
        var p = Project.new()
        let a = audioClip(id: "a", start: 0, duration: 6)
        let later = audioClip(id: "later", start: 6, duration: 2)
        var tr = Track(name: "音"); tr.clips = [a, later]
        p.tracks = [tr]
        let sentences = [TranscriptSentence(text: "一", start: 0, end: 2), TranscriptSentence(text: "二", start: 2, end: 3.5), TranscriptSentence(text: "三", start: 4, end: 6)]
        // 「二」(2〜3.5 秒)を外す → 残りを詰める。後ろのクリップは 1.5 秒左へ
        let cuts = TranscriptTextEdit.cuts(for: [sentences[1]])
        let r = try XCTUnwrap(ClipEditing.removeSilence(in: p, clipId: "a", cuts: cuts, ripple: true))
        let clips = r.project.tracks[0].clips
        XCTAssertEqual(clips.map(\.duration).reduce(0, +), 4.5 + 2, accuracy: 0.01, "取り除いた 1.5 秒ぶん短い")
        let laterNow = try XCTUnwrap(clips.first { $0.id == "later" })
        XCTAssertEqual(laterNow.start, 4.5, accuracy: 0.01, "後ろのクリップは詰める")
    }

    func testRemovingEverySentenceIsRefusedAndChangesNothing() {
        var p = Project.new()
        var tr = Track(name: "音"); tr.clips = [audioClip(id: "a", start: 0, duration: 2)]
        p.tracks = [tr]
        let all = [TranscriptSentence(text: "一", start: 0, end: 1), TranscriptSentence(text: "二", start: 1, end: 2)]
        XCTAssertNil(ClipEditing.removeSilence(in: p, clipId: "a", cuts: TranscriptTextEdit.cuts(for: all), ripple: true), "全部の文を外すとクリップが無くなるので切らない")
        XCTAssertEqual(TranscriptTextEdit.cuts(for: []), [])
    }
}
