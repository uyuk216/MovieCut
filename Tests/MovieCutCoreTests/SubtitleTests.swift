import XCTest
@testable import MovieCutCore

/// B3: SRT/VTT の整形・読み取り・読み込み(プロジェクトへ)・チャプター。
final class SubtitleTests: XCTestCase {
    private func cue(_ s: Double, _ e: Double, _ t: String) -> SubtitleCue { SubtitleCue(start: s, end: e, text: t) }

    // MARK: 整形

    func testTimestampFormats() {
        XCTAssertEqual(SubtitleFile.timestamp(0, format: .srt), "00:00:00,000")
        XCTAssertEqual(SubtitleFile.timestamp(1.5, format: .vtt), "00:00:01.500")
        XCTAssertEqual(SubtitleFile.timestamp(359_999.999, format: .srt), "99:59:59,999")
        XCTAssertEqual(SubtitleFile.timestamp(360_000, format: .srt), "100:00:00,000", "99 時間を超えても桁を増やす")
        XCTAssertEqual(SubtitleFile.timestamp(-3, format: .srt), "00:00:00,000")
        XCTAssertEqual(SubtitleFile.timestamp(.nan, format: .srt), "00:00:00,000")
        XCTAssertEqual(SubtitleFile.timestamp(1.0005, format: .srt), "00:00:01,001", "ミリ秒に丸める")
    }

    func testFormatSRTNumbersAndSkipsEmpty() {
        let out = SubtitleFile.format([cue(0, 1, "あ"), cue(1, 2, "  \n "), cue(2, 2, "長さ0"), cue(3, 4.25, "い\n\nう")], as: .srt)
        XCTAssertEqual(out, "1\n00:00:00,000 --> 00:00:01,000\nあ\n\n2\n00:00:03,000 --> 00:00:04,250\nい\nう\n\n")
    }

    func testFormatVTTHeaderAndPeriod() {
        let out = SubtitleFile.format([cue(0, 1.5, "a --> b")], as: .vtt)
        XCTAssertEqual(out, "WEBVTT\n\n00:00:00.000 --> 00:00:01.500\na -> b\n\n")
        XCTAssertEqual(SubtitleFile.format([], as: .vtt), "WEBVTT\n\n")
        XCTAssertEqual(SubtitleFile.format([], as: .srt), "")
    }

    // MARK: 読み取り

    func testRoundTripBothFormatsWithUnicode() {
        let cues = [cue(0, 1.234, "こんにちは🙂"), cue(2, 3.5, "二行目\nはここ"), cue(3599.999, 7200, "漢字")]
        for f in SubtitleFormat.allCases {
            XCTAssertEqual(SubtitleFile.parse(SubtitleFile.format(cues, as: f)), cues, "\(f)")
        }
    }

    func testParseBOMCRLFAndMissingNumbers() {
        let s = "\u{FEFF}1\r\n00:00:01,000 --> 00:00:02,000\r\nA\r\n\r\n00:00:03,000 --> 00:00:04,000\r\nB\r\nB2\r\n"
        XCTAssertEqual(SubtitleFile.parse(s), [cue(1, 2, "A"), cue(3, 4, "B\nB2")])
        XCTAssertEqual(SubtitleFile.parse("1\r00:00:01,000 --> 00:00:02,000\rA\r"), [cue(1, 2, "A")], "CR だけの改行")
    }

    func testParseCommaAndPeriodAndShortForms() {
        let s = "1\n00:00:01,5 --> 00:00:02.25\nx\n\n2\n01:02.500 --> 01:03.000\ny\n\n3\n99:59:59,999 --> 100:00:00,000\nz\n"
        let r = SubtitleFile.parse(s)
        XCTAssertEqual(r.count, 3)
        XCTAssertEqual(r[0].start, 1.5, accuracy: 1e-9)
        XCTAssertEqual(r[0].end, 2.25, accuracy: 1e-9)
        XCTAssertEqual(r[1].start, 62.5, accuracy: 1e-9, "VTT は時を省ける")
        XCTAssertEqual(r[2].start, 359_999.999, accuracy: 1e-6)
    }

    func testParseVTTHeaderNotesStylesSettingsTags() {
        let s = """
        WEBVTT - 題名

        NOTE これはコメント
        2行目

        STYLE
        ::cue { color: red }

        REGION
        id:r1

        intro
        00:00:01.000 --> 00:00:02.000 align:start position:10%
        <v 太郎><i>こんにちは</i></v> &amp; <c.red>やあ</c> <00:00:01.500>ね

        00:00:03.000 --> 00:00:04.000
        {\\an8}上の字幕
        """
        XCTAssertEqual(SubtitleFile.parse(s), [cue(1, 2, "こんにちは & やあ ね"), cue(3, 4, "上の字幕")])
    }

    func testParseRubyKeepsBaseText() {
        let s = "00:00:00.000 --> 00:00:01.000\n<ruby>漢字<rp>(</rp><rt>かんじ</rt><rp>)</rp></ruby>です\n"
        XCTAssertEqual(SubtitleFile.parse(s), [cue(0, 1, "漢字です")])
    }

    func testParseDropsEmptyAndBrokenAndKeepsOverlaps() {
        let s = "1\n00:00:01,000 --> 00:00:02,000\n\n\n2\nxx --> yy\nbad\n\n3\n00:00:02,000 --> 00:00:05,000\nlong\n\n4\n00:00:01,000 --> 00:00:03,000\nover\n\n5\n00:00:00,500 --> 00:00:00,900\n<i></i>\n"
        XCTAssertEqual(SubtitleFile.parse(s), [cue(1, 3, "over"), cue(2, 5, "long")], "空・読めない件は捨て、重なる件は残し、開始順")
        XCTAssertEqual(SubtitleFile.parse(""), [])
        XCTAssertEqual(SubtitleFile.parse("ただの文章\nです"), [])
    }

    func testLessThanSignInTextSurvives() {
        XCTAssertEqual(SubtitleFile.parse("00:00:00,000 --> 00:00:01,000\n1 < 2 かつ 3 > 2\n"), [cue(0, 1, "1 < 2 かつ 3 > 2")])
    }

    // MARK: プロジェクトから書き出し

    private func fixture() throws -> Project {
        try Project.load(from: XCTUnwrap(Bundle.module.url(forResource: "subtitles", withExtension: "ymproj", subdirectory: "Fixtures")))
    }

    func testCuesFromProjectPicksVoiceSubtitlesAndSubtitleLayerText() throws {
        let cues = SubtitleFile.cues(from: try fixture())
        XCTAssertEqual(cues.map(\.text), ["こんにちは\nこんにちは", "文字クリップ", "二番目"], "字幕オフのボイスと、ふつうのレイヤーの文字は出さない")
        XCTAssertEqual(cues[2].start, 12.0345, accuracy: 1e-9)
        XCTAssertEqual(cues[2].end, 15.0345, accuracy: 1e-9)
        let srt = SubtitleFile.format(cues, as: .srt)
        XCTAssertTrue(srt.contains("3\n00:00:12,035 --> 00:00:15,035\n二番目"), srt)
    }

    func testTimingIgnoresSpeedAndHiddenLayers() throws {
        var p = try fixture()
        // 速度は動画・音声だけの属性。ボイス・文字に付いていても、タイムライン上の開始と長さがそのまま使われる
        p.tracks[0].clips[0].speed = 4
        XCTAssertEqual(SubtitleFile.cues(from: p)[0].end, 2.5, accuracy: 1e-9)
        p.tracks[0].hidden = true
        XCTAssertEqual(SubtitleFile.cues(from: p).map(\.text), ["文字クリップ"], "隠したレイヤーは出さない(描画と同じ)")
    }

    func testSubtitleLayerNames() {
        XCTAssertTrue(SubtitleFile.isSubtitleLayer("字幕"))
        XCTAssertTrue(SubtitleFile.isSubtitleLayer("字幕 2"))
        XCTAssertFalse(SubtitleFile.isSubtitleLayer("字幕x"))
        XCTAssertFalse(SubtitleFile.isSubtitleLayer("レイヤー1"))
    }

    // MARK: 読み込み

    func testImportCreatesSubtitleLayerWithStyling() throws {
        let p0 = try fixture()
        let r = try XCTUnwrap(SubtitleImport.apply([cue(1, 2, "あ"), cue(3, 4, "い")], to: p0))
        XCTAssertEqual(r.project.tracks.count, p0.tracks.count + 1)
        let t = try XCTUnwrap(r.project.tracks.last)
        XCTAssertEqual(t.name, "字幕")
        XCTAssertEqual(t.clips.map(\.text), ["あ", "い"])
        XCTAssertEqual(t.clips.map(\.id), r.clipIds)
        let c = t.clips[0]
        XCTAssertEqual(c.type, .text)
        XCTAssertEqual(c.start, 1); XCTAssertEqual(c.duration, 1)
        XCTAssertEqual(c.y, 0.88); XCTAssertEqual(c.colorOrDefault, "#ffffff"); XCTAssertEqual(c.outlineOrDefault, "#000000")
        XCTAssertEqual(c.fontSize, (64 * ClipEditing.resK(p0)).rounded(), "1280x720 では 64 より小さい")
        XCTAssertEqual(p0.tracks.count, r.project.tracks.count - 1, "元の側は変わらない")
    }

    func testImportOffsetClampAndOverlapLanes() throws {
        let p0 = Project.new()
        let r = try XCTUnwrap(SubtitleImport.apply([cue(0, 1, "消える"), cue(1, 4, "a"), cue(2, 3, "b"), cue(4, 5, "c")], to: p0, offset: -0.5))
        // -0.5 秒: 消える は終わりが 0.5 → 0〜0.5 に切って残る。a は 0.5〜3.5、b は 1.5〜2.5(重なる)、c は 3.5〜4.5
        let tracks = Array(r.project.tracks.suffix(2))
        XCTAssertEqual(tracks.map(\.name), ["字幕", "字幕 2"])
        XCTAssertEqual(tracks[0].clips.map(\.text), ["消える", "a", "c"])
        XCTAssertEqual(tracks[1].clips.map(\.text), ["b"])
        XCTAssertEqual(tracks[0].clips[0].start, 0); XCTAssertEqual(tracks[0].clips[0].duration, 0.5, accuracy: 1e-9)
        XCTAssertEqual(tracks[0].clips[1].start, 0.5, accuracy: 1e-9)
        XCTAssertNil(SubtitleImport.apply([cue(0, 1, "x")], to: p0, offset: -5), "全部が 0 秒より前なら何も足さない")
        XCTAssertNil(SubtitleImport.apply([], to: p0))
    }

    func testImportedLayerRoundTripsThroughExport() throws {
        let cues = [cue(1, 2.5, "あ"), cue(2, 3, "重なり"), cue(4, 5, "い")]
        let r = try XCTUnwrap(SubtitleImport.apply(cues, to: Project.new()))
        XCTAssertEqual(SubtitleFile.cues(from: r.project), cues)
    }

    func testImportedProjectSavesAndReloads() throws {
        let r = try XCTUnwrap(SubtitleImport.apply([cue(1, 2, "あ")], to: Project.new()))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sub-\(UUID().uuidString).mcpjc")
        defer { try? FileManager.default.removeItem(at: url) }
        try r.project.save(to: url)
        XCTAssertEqual(try Project.load(from: url), r.project)
    }

    // MARK: チャプター

    func testChapterTimecodes() {
        XCTAssertEqual(Chapters.timecode(0), "0:00")
        XCTAssertEqual(Chapters.timecode(65.9), "1:05", "秒は切り捨て")
        XCTAssertEqual(Chapters.timecode(3599.99), "59:59")
        XCTAssertEqual(Chapters.timecode(3725), "1:02:05")
    }

    func testChaptersFromFixtureMarkers() throws {
        let r = Chapters.make(from: try fixture().markers)
        XCTAssertEqual(r.text, "0:00 はじめに\n1:05 本題\n1:02:05 おわり")
        XCTAssertEqual(r.count, 3)
        XCTAssertEqual(r.warnings, [])
    }

    func testChaptersAddIntroAndWarn() {
        let r = Chapters.make(from: [Marker(time: 30, name: "B"), Marker(time: 35, name: "  C\nD ")])
        XCTAssertEqual(r.text, "0:00 イントロ\n0:30 B\n0:35 C D", "先頭に 0:00 を足し、題は 1 行に")
        XCTAssertEqual(r.count, 3)
        XCTAssertEqual(r.warnings.count, 2)
        XCTAssertTrue(r.warnings[0].contains("0:00"))
        XCTAssertTrue(r.warnings[1].contains("10 秒より近い"))
    }

    func testChaptersFewAndEmpty() {
        let two = Chapters.make(from: [Marker(time: 0, name: "A"), Marker(time: 20, name: "")])
        XCTAssertEqual(two.text, "0:00 A\n0:20 チャプター")
        XCTAssertEqual(two.warnings.count, 1)
        XCTAssertTrue(two.warnings[0].contains("3 つ以上"))
        let none = Chapters.make(from: [])
        XCTAssertEqual(none.text, ""); XCTAssertEqual(none.count, 0); XCTAssertEqual(none.warnings.count, 1)
    }

    func testChaptersSortByTime() {
        let r = Chapters.make(from: [Marker(time: 40, name: "C"), Marker(time: 0, name: "A"), Marker(time: 20, name: "B")])
        XCTAssertEqual(r.text, "0:00 A\n0:20 B\n0:40 C")
        XCTAssertEqual(r.warnings, [])
    }
}
