import XCTest
@testable import MovieCutCore

/// フィラー語の区間(FillerDetector)。認識の単語の時刻から探し、既存の無音カット(後ろを詰める)でカットする。
final class FillerCutTests: XCTestCase {
    private func w(_ t: String, _ a: Double, _ b: Double) -> TranscriptSegment { TranscriptSegment(text: t, start: a, end: b) }

    /// テスト用の認識器(決めた単語を返す)。
    final class FakeWords: Transcriber, @unchecked Sendable {
        let words: [TranscriptSegment]
        init(_ words: [TranscriptSegment]) { self.words = words }
        func transcribe(audioURL: URL, duration: Double, onProgress: @escaping @Sendable (Double) -> Void) async throws -> [TranscriptSegment] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path), "認識器に音声ファイルが渡る")
            return words
        }
    }

    func testFindsSingleWordInsideSentence() {
        let r = FillerDetector.find(in: [w("今日は", 0, 0.5), w("えー", 0.6, 1.0), w("天気", 1.1, 1.5)])
        XCTAssertEqual(r, [FillerRange(text: "えー", start: 0.6, end: 1.0)])
    }

    func testJoinsSplitTokensWhenTheyFollowWithinGap() {
        let r = FillerDetector.find(in: [w("え", 0, 0.2), w("ー", 0.25, 0.5)])
        XCTAssertEqual(r, [FillerRange(text: "えー", start: 0, end: 0.5)])
    }

    func testDoesNotJoinAcrossALongGap() {
        XCTAssertEqual(FillerDetector.find(in: [w("え", 0, 0.2), w("ー", 2.0, 2.3)]), [])
    }

    func testPunctuationAndSpacesAreIgnoredButProlongMarkIsNot() {
        XCTAssertEqual(FillerDetector.find(in: [w("えー、", 0, 0.5)]).map(\.text), ["えー"])
        XCTAssertEqual(FillerDetector.find(in: [w("え ー", 0, 0.5)]).map(\.text), ["えー"])
        XCTAssertEqual(FillerDetector.find(in: [w("映画", 0, 0.5), w("日和", 1, 1.5)]), [], "普通の語は見つけない")
    }

    func testFindsSeveralNonOverlappingInOrder() {
        let r = FillerDetector.find(in: [w("あの", 0, 0.3), w("えーと", 0.4, 1.0), w("その", 1.1, 1.4), w("本題", 1.5, 2)])
        XCTAssertEqual(r.map(\.text), ["あの", "えーと", "その"])
        XCTAssertEqual(r.map(\.start), [0, 0.4, 1.1])
    }

    func testCutsMapToSilenceRanges() {
        let cuts = FillerDetector.cuts([FillerRange(text: "えー", start: 1, end: 1.5)])
        XCTAssertEqual(cuts, [SilenceRange(start: 1, end: 1.5)])
    }

    func testCuttingWithRippleClosesTheGapLikeSilenceCut() throws {
        var a = Clip(); a.id = "a"; a.type = .audio; a.start = 0; a.duration = 4; a.src = "tone.wav"
        var b = Clip(); b.id = "b"; b.type = .audio; b.start = 4; b.duration = 2; b.src = "tone.wav"
        var t = Track(name: "音"); t.clips = [a, b]
        var p = Project.new(); p.tracks = [t]
        let found = FillerDetector.find(in: [w("えー", 1, 1.5)])
        let r = try XCTUnwrap(ClipEditing.removeSilence(in: p, clipId: "a", cuts: FillerDetector.cuts(found), ripple: true))
        let clips = r.project.tracks[0].clips
        XCTAssertEqual(clips.count, 3, "語の前と後ろに分かれる(後ろのクリップは別)")
        XCTAssertEqual(clips[0].duration, 1, accuracy: 1e-9)
        XCTAssertEqual(clips[1].start, 1, accuracy: 1e-9, "後ろの断片は前へ詰める")
        XCTAssertEqual(clips[1].duration, 2.5, accuracy: 1e-9)
        XCTAssertEqual(clips[2].start, 3.5, accuracy: 1e-9, "同じレイヤーの後ろのクリップも取った長さだけ前へ")
    }

    func testRunUsesTranscriberWordsAndCleansUpTempFile() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "aq_reimu", withExtension: "wav", subdirectory: "Fixtures"))
        var c = Clip(); c.type = .audio; c.start = 0; c.duration = 1; c.src = url.path
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("filler-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let found = try await FillerDetector.run(clip: c, transcriber: FakeWords([w("えー", 0.2, 0.6), w("こんにちは", 0.7, 1)]), tempDirectory: dir)
        XCTAssertEqual(found, [FillerRange(text: "えー", start: 0.2, end: 0.6)])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).count, 0, "一時ファイルは終わったら消える")
    }
}
