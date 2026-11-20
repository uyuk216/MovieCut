import XCTest
@testable import MovieCutCore

/// 台本 CSV の書き出しと往復(#42): 特殊文字・読み・字幕の 3 状態・表情・メモ行が保たれること。
final class ScriptCSVRoundTripTests: XCTestCase {
    typealias Row = ScriptCSV.Row

    // MARK: 行 → CSV → 行 の往復

    func testRowsRoundTripPreservesSpecialCharacters() {
        let rows: [Row] = [
            Row(characterName: "キャラ1", dialogue: "ねえ、聞いて", reading: "ねえ、きいて", expression: "笑顔"),
            Row(characterName: "キャラ2", dialogue: "カンマ,と\"引用\"と\n改行", subtitle: "字幕,あり"),
            Row(characterName: "キャラ1", dialogue: "相棒", reading: "あいぼう"),
            Row(characterName: "キャラ2", dialogue: "字幕なしの行", subtitle: ""),
            Row(characterName: "", dialogue: "名前なし"),
            Row(dialogue: "※ ここはメモ"),
        ]
        let csv = ScriptCSV.csv(from: rows)
        XCTAssertTrue(csv.hasPrefix("\u{FEFF}"), "BOM つき(表計算ソフトで日本語が崩れない)")
        XCTAssertTrue(csv.contains("\r\n"), "改行は CRLF")
        let back = ScriptCSV.scriptRows(fromCSV: csv)
        XCTAssertEqual(back, rows, "書き出し → 読み込みで同じ行に戻る")
    }

    func testSubtitleThreeStatesSurviveRoundTrip() {
        // 字幕: nil(指定なし) / ""(字幕なし) / 文 の 3 状態が区別される
        let rows: [Row] = [
            Row(characterName: "A", dialogue: "そのまま"),
            Row(characterName: "A", dialogue: "消す", subtitle: ""),
            Row(characterName: "A", dialogue: "変える", subtitle: "表示だけ"),
        ]
        let back = ScriptCSV.scriptRows(fromCSV: ScriptCSV.csv(from: rows))
        XCTAssertNil(back[0].subtitle)
        XCTAssertEqual(back[1].subtitle, "")
        XCTAssertEqual(back[2].subtitle, "表示だけ")
        // 台本の行に直したときの形
        XCTAssertEqual(back.map(\.scriptLine), ["A: そのまま", "A: 消す |", "A: 変える | 表示だけ"])
    }

    func testReadingFallsBackToDialogueInScriptLine() {
        let withReading = Row(characterName: "キャラ1", dialogue: "相棒", reading: "あいぼう")
        XCTAssertEqual(withReading.scriptLine, "キャラ1: あいぼう | 相棒",
                       "読みが違えば字幕は元の表記(読み辞書で作ったクリップと同じ形)")
        XCTAssertEqual(withReading.clipSubtitleText, "相棒")
        let plain = Row(characterName: "キャラ1", dialogue: "こんにちは")
        XCTAssertEqual(plain.scriptLine, "キャラ1: こんにちは")
        XCTAssertNil(plain.clipSubtitleText)
    }

    // MARK: 読み込みの形(見出し・列数)

    func testHeaderReorderingWithAllColumns() {
        let csv = "字幕,表情,読み,セリフ,キャラ\r\n字幕A,笑顔,よみA,表記A,キャラ1\r\n, ,よみB,表記B,キャラ2"
        let rows = ScriptCSV.scriptRows(fromCSV: csv)
        XCTAssertEqual(rows, [
            Row(characterName: "キャラ1", dialogue: "表記A", reading: "よみA", subtitle: "字幕A", expression: "笑顔"),
            Row(characterName: "キャラ2", dialogue: "表記B", reading: "よみB"),
        ])
    }

    func testLegacyHeaderWithoutDialogueColumnTreatsReadingAsSpoken() {
        // 従来形式の見出し(名前,読み上げ文,字幕): 読み上げ文がセリフ欄に入る
        let csv = "名前,読み上げ文,字幕\nキャラ1,あいぼう,相棒"
        let rows = ScriptCSV.scriptRows(fromCSV: csv)
        XCTAssertEqual(rows, [Row(characterName: "キャラ1", dialogue: "あいぼう", subtitle: "相棒")])
        XCTAssertEqual(ScriptCSV.lines(fromRows: rows), ScriptCSV.lines(fromCSV: csv))
    }

    func testHeaderlessColumnCounts() {
        XCTAssertEqual(ScriptCSV.scriptRows(fromCSV: "セリフだけ"),
                       [Row(dialogue: "セリフだけ")])
        XCTAssertEqual(ScriptCSV.scriptRows(fromCSV: "キャラ1,こんにちは"),
                       [Row(characterName: "キャラ1", dialogue: "こんにちは")])
        // 4 列(見出しなし) = キャラ,セリフ,読み,字幕
        XCTAssertEqual(ScriptCSV.scriptRows(fromCSV: "キャラ1,相棒,あいぼう,"),
                       [Row(characterName: "キャラ1", dialogue: "相棒", reading: "あいぼう")])
        XCTAssertEqual(ScriptCSV.scriptRows(fromCSV: "キャラ1,相棒,あいぼう,")[0].scriptLine, "キャラ1: あいぼう | 相棒")
    }

    func testLegacySamplesMatchExistingLinesConversion() {
        // 既存の ScriptCSV.lines(fromCSV:) と、行経由の変換が同じ台本行を出す(従来 CSV の互換)
        let samples = [
            "キャラ1,こんにちは,こんにちは(字幕)\nキャラ2,やあ,\n\nキャラ1,字幕なしの行",
            "字幕,名前,セリフ\n字幕A,キャラ1,読みA\n,キャラ2,読みB",
            "※ ここはメモ\n,名前なしのセリフ",
            "セリフだけ1\nセリフだけ2",
            "キャラ1,\"ねえ、聞いて\",字幕です",
        ]
        for csv in samples {
            XCTAssertEqual(ScriptCSV.lines(fromRows: ScriptCSV.scriptRows(fromCSV: csv)),
                           ScriptCSV.lines(fromCSV: csv), "対象: \(csv)")
        }
    }

    func testQuotedEmptySubtitleMeansNoSubtitle() {
        let rows = ScriptCSV.scriptRows(fromCSV: "キャラ,セリフ,読み,字幕,表情\nキャラ1,消える,,\"\",")
        XCTAssertEqual(rows.first?.subtitle, "")
        let unspecified = ScriptCSV.scriptRows(fromCSV: "キャラ,セリフ,読み,字幕,表情\nキャラ1,残る,,,")
        XCTAssertNil(unspecified.first?.subtitle)
    }

    func testExpressionBracketsAreStrippedOnImport() {
        let rows = ScriptCSV.scriptRows(fromCSV: "キャラ,セリフ,読み,字幕,表情\nキャラ1,やあ,,,[笑顔]")
        XCTAssertEqual(rows.first?.expression, "笑顔")
        XCTAssertEqual(rows.first?.spokenText, "[笑顔]やあ")
    }

    // MARK: プロジェクト → CSV → 行 → クリップ相当 の往復

    private func sampleProject() -> Project {
        var p = Project()
        var c1 = Character(); c1.name = "キャラ1"
        var c2 = Character(); c2.name = "キャラ2"
        p.characters = [c1, c2]
        func voice(_ char: Character, _ text: String, _ sub: String?, _ start: Double) -> Clip {
            var c = Clip(); c.type = .voice; c.text = text; c.subtitleText = sub
            c.charId = char.id; c.start = start; c.duration = 1
            return c
        }
        var track = Track(name: "ボイス")
        track.clips = [
            voice(c2, "あとから", nil, 5),                       // 開始順に並べ替わる
            voice(c1, "こんにちは", nil, 0),                     // ふつうの行
            voice(c1, "あいぼう", "相棒", 1),                    // 読みだけ違う(辞書形)
            voice(c2, "[笑顔]やった", nil, 2),                   // 表情タグ
            voice(c2, "字幕なし", "", 3),                        // 字幕なし
            voice(c1, "読みは同じ", "表示だけ別の字幕", 4),      // 字幕だけ別
            voice(c1, "", nil, 6),                               // セリフが空 = 書けない
        ]
        p.tracks = [track]
        return p
    }

    func testProjectExportShape() {
        let r = ScriptCSV.rows(from: sampleProject())
        XCTAssertEqual(r.skipped, 1, "セリフが空のクリップは数える")
        XCTAssertEqual(r.rows.map(\.characterName), ["キャラ1", "キャラ1", "キャラ2", "キャラ2", "キャラ1", "キャラ2"])
        XCTAssertEqual(r.rows[1], Row(characterName: "キャラ1", dialogue: "相棒", reading: "あいぼう"),
                       "読み辞書形は セリフ=元の表記 / 読み=読み上げ文 に分かれる")
        XCTAssertEqual(r.rows[2].expression, "笑顔")
        XCTAssertEqual(r.rows[2].dialogue, "やった")
        XCTAssertEqual(r.rows[3].subtitle, "")
        XCTAssertEqual(r.rows[4].dialogue, "表示だけ別の字幕")
        XCTAssertEqual(r.rows[4].reading, "読みは同じ")
    }

    func testProjectRoundTripPreservesClipTextAndSubtitle() {
        let p = sampleProject()
        let original = ScriptTable.lines(in: p)   // (読み上げ文, 字幕文, 表情, キャラ名) の正規形
        let exported = ScriptCSV.csv(from: p)
        XCTAssertEqual(exported.lineCount, 6)
        XCTAssertEqual(exported.skipped, 1)
        let rows = ScriptCSV.scriptRows(fromCSV: exported.text)
        XCTAssertEqual(rows.count, original.count)
        for (row, line) in zip(rows, original) {
            XCTAssertEqual(row.characterName, line.characterName)
            XCTAssertEqual(row.spokenText, line.clipText, "読み上げ文(タグ込み)が保たれる")
            XCTAssertEqual(row.clipSubtitleText, line.subtitle, "字幕文が保たれる")
        }
        // 台本テキスト経由でも同じ行に戻る
        let lines = ScriptCSV.lines(fromRows: rows)
        XCTAssertEqual(lines, VoiceScriptExport.make(p).text.components(separatedBy: "\n"))
    }

    func testExportOfEmptyProjectIsHeaderOnly() {
        let r = ScriptCSV.csv(from: Project())
        XCTAssertEqual(r.lineCount, 0)
        XCTAssertEqual(ScriptCSV.scriptRows(fromCSV: r.text), [])
    }
}
