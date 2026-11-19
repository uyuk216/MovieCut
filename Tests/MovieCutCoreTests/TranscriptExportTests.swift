import XCTest
@testable import MovieCutCore

final class TranscriptExportTests: XCTestCase {
    func testSegmentsToPlainText() {
        let segs = [
            TranscriptSegment(text: " こんにちは ", start: 0, end: 1),
            TranscriptSegment(text: "  ", start: 1, end: 2),
            TranscriptSegment(text: "二行目\n折り返し", start: 2, end: 3),
        ]
        XCTAssertEqual(TranscriptText.plainText(from: segs), "こんにちは\n二行目 折り返し\n")
    }

    func testEmptyGivesEmptyString() {
        XCTAssertEqual(TranscriptText.plainText(from: [TranscriptSegment]()), "")
        XCTAssertEqual(TranscriptText.plainText(from: [TranscriptSegment(text: " ", start: 0, end: 1)]), "")
        XCTAssertEqual(TranscriptText.plainText(from: [SubtitleCue]()), "")
    }

    func testCuesToPlainTextAndFormat() {
        let cues = [SubtitleCue(start: 0, end: 1.5, text: "はじめ"), SubtitleCue(start: 2, end: 3, text: "おわり")]
        XCTAssertEqual(TranscriptText.plainText(from: cues), "はじめ\nおわり\n")
        XCTAssertEqual(TranscriptText.string(for: .txt, cues: cues), "はじめ\nおわり\n")
        let srt = TranscriptText.string(for: .srt, cues: cues)
        XCTAssertEqual(srt, SubtitleFile.format(cues, as: .srt))
        XCTAssertTrue(srt.contains("-->"))
    }

    func testMixedLanguageKept() {
        let t = "今日は Meeting をします。次は Deploy です"
        XCTAssertEqual(TranscriptText.plainText(from: [TranscriptSegment(text: t, start: 0, end: 1)]), t + "\n")
        XCTAssertEqual(TranscriptText.plainText(from: [SubtitleCue(start: 0, end: 1, text: t)]), t + "\n")
    }

    func testFormatPathExtension() {
        XCTAssertEqual(TranscriptExportFormat(pathExtension: "txt"), .txt)
        XCTAssertEqual(TranscriptExportFormat(pathExtension: "SRT"), .srt)
        XCTAssertNil(TranscriptExportFormat(pathExtension: "vtt"))
        XCTAssertNil(TranscriptExportFormat(pathExtension: ""))
        XCTAssertEqual(TranscriptExportFormat.srt.fileExtension, "srt")
        XCTAssertEqual(TranscriptExportFormat.srt.subtitleFormat, .srt)
        XCTAssertNil(TranscriptExportFormat.txt.subtitleFormat)
    }

    func testCharacterErrorRate() {
        XCTAssertEqual(CharacterErrorRate.rate(reference: "今日は晴れ", hypothesis: "今日は晴れ"), 0)
        XCTAssertEqual(CharacterErrorRate.rate(reference: "", hypothesis: ""), 0)
        XCTAssertEqual(CharacterErrorRate.rate(reference: "", hypothesis: "あ"), 1)
        // 1文字置換: 5文字中1つ
        XCTAssertEqual(CharacterErrorRate.rate(reference: "今日は晴れ", hypothesis: "今日は晴る"), 0.2, accuracy: 1e-9)
        // 空白と大文字小文字は無視
        XCTAssertEqual(CharacterErrorRate.rate(reference: "Hello World", hypothesis: "hello  world"), 0)
        // 全く違う文は高い
        XCTAssertGreaterThanOrEqual(CharacterErrorRate.rate(reference: "あいうえお", hypothesis: "かきくけこ"), 1)
        // 認識が空なら全部脱落
        XCTAssertEqual(CharacterErrorRate.rate(reference: "あいう", hypothesis: ""), 1)
    }
}
