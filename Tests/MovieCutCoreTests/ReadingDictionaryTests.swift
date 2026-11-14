import XCTest
@testable import MovieCutCore

/// 読み辞書(表記 → 読み): 適用・テキスト形式・プロジェクト保存・台本への統合。
final class ReadingDictionaryTests: XCTestCase {
    var tmp: URL!
    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("reading-dict-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private var entries: [ReadingEntry] {
        [ReadingEntry(word: "相棒", reading: "あいぼう"),
         ReadingEntry(word: "本音", reading: "ほんね"),
         ReadingEntry(word: "正直", reading: "しょうじき")]
    }

    func testApplyBasic() {
        XCTAssertEqual(ReadingDictionary.apply(to: "相棒と本音を話す", entries: entries), "あいぼうとほんねを話す")
        XCTAssertEqual(ReadingDictionary.apply(to: "関係ない文", entries: entries), "関係ない文")
        XCTAssertEqual(ReadingDictionary.apply(to: "相棒", entries: []), "相棒")
        XCTAssertEqual(ReadingDictionary.apply(to: "", entries: entries), "")
    }

    func testApplyLongestFirstAndNoRematch() {
        // 長い表記が優先される
        let e = [ReadingEntry(word: "本", reading: "もと"), ReadingEntry(word: "本音", reading: "ほんね")]
        XCTAssertEqual(ReadingDictionary.apply(to: "本音と本", entries: e), "ほんねともと")
        // 置き換えた読みの中の表記は再照合しない
        let loop = [ReadingEntry(word: "甲", reading: "乙"), ReadingEntry(word: "乙", reading: "おつ")]
        XCTAssertEqual(ReadingDictionary.apply(to: "甲", entries: loop), "乙")
        // 空の表記・読みは無視される
        let blanks = [ReadingEntry(word: "", reading: "x"), ReadingEntry(word: "y", reading: "")]
        XCTAssertEqual(ReadingDictionary.apply(to: "y", entries: blanks), "y")
    }

    func testApplyKeepsExpressionTag() {
        XCTAssertEqual(ReadingDictionary.apply(to: "[笑顔]相棒だ", entries: entries), "[笑顔]あいぼうだ")
        // タグ名そのものは変換しない(辞書に同じ語があっても)
        let e = [ReadingEntry(word: "笑顔", reading: "えがお")]
        XCTAssertEqual(ReadingDictionary.apply(to: "[笑顔]こんにちは", entries: e), "[笑顔]こんにちは")
    }

    func testParseAndSerialize() {
        let text = """
        # コメント
        相棒,あいぼう
        本音\tほんね
        正直=しょうじき
        ※ メモ行
        区切りの無い行
        相棒,かさね(重複は最初の勝ち)
        ,読みだけ
        表記だけ,
        """
        let parsed = ReadingDictionary.parse(text: text)
        XCTAssertEqual(parsed, [ReadingEntry(word: "相棒", reading: "あいぼう"),
                                ReadingEntry(word: "本音", reading: "ほんね"),
                                ReadingEntry(word: "正直", reading: "しょうじき")])
        XCTAssertEqual(ReadingDictionary.parse(text: ReadingDictionary.serialized(parsed)), parsed)
    }

    func testProjectRoundTrip() throws {
        var p = Project.new()
        // 辞書が空ならファイルに書かない
        let emptyData = try JSONEncoder().encode(p)
        XCTAssertFalse(String(data: emptyData, encoding: .utf8)?.contains("readingDictionary") ?? true)
        p.readingDictionary = entries
        let data = try JSONEncoder().encode(p)
        XCTAssertTrue(String(data: data, encoding: .utf8)?.contains("readingDictionary") ?? false)
        let back = try JSONDecoder().decode(Project.self, from: data)
        XCTAssertEqual(back.readingDictionary, entries)
        XCTAssertEqual(back, p)
    }

    /// 台本から声を作るとき: 読み上げ文は辞書適用後、字幕は元の表記。
    func testScriptAddAppliesDictionary() async throws {
        var p = Project.new()
        p.readingDictionary = entries
        let tone = ToneVoiceProvider(durations: [1.0], frequencies: [220])
        let added = try await ScriptTimeline.add(lines: [
            "キャラ1: 相棒の本音",
            "キャラ1: 正直に言う | 正直に言う(字幕)",
            "キャラ1: 辞書に無い文",
        ], to: &p, voice: tone, directory: tmp)
        XCTAssertEqual(added.count, 3)
        XCTAssertEqual(added[0].text, "あいぼうのほんね")
        XCTAssertEqual(added[0].subtitleText, "相棒の本音")   // 字幕は元の表記
        XCTAssertEqual(added[1].text, "しょうじきに言う")
        XCTAssertEqual(added[1].subtitleText, "正直に言う(字幕)")   // 明示の字幕が優先
        XCTAssertEqual(added[2].text, "辞書に無い文")
        XCTAssertNil(added[2].subtitleText)
    }

    /// 辞書が無ければ従来どおり(読み上げ文 = 字幕)。
    func testScriptAddWithoutDictionary() async throws {
        var p = Project.new()
        let tone = ToneVoiceProvider(durations: [1.0], frequencies: [220])
        let added = try await ScriptTimeline.add(lines: ["キャラ1: 相棒の本音"], to: &p, voice: tone, directory: tmp)
        XCTAssertEqual(added[0].text, "相棒の本音")
        XCTAssertNil(added[0].subtitleText)
    }

    func testNormalized() {
        let raw = [ReadingEntry(word: "", reading: "x"),
                   ReadingEntry(word: "相棒", reading: ""),
                   ReadingEntry(word: "相棒", reading: "あいぼう"),
                   ReadingEntry(word: "相棒", reading: "あいぼー"),
                   ReadingEntry(word: "本音", reading: "ほんね")]
        XCTAssertEqual(ReadingDictionary.normalized(raw),
                       [ReadingEntry(word: "相棒", reading: "あいぼう"), ReadingEntry(word: "本音", reading: "ほんね")])
        XCTAssertEqual(ReadingDictionary.normalized([]), [])
    }
}
