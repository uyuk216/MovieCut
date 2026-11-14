import XCTest
@testable import MovieCutCore

/// 台本 CSV の分解と、台本の行への変換。
final class ScriptCSVTests: XCTestCase {
    func testRowsBasicAndEscapes() {
        XCTAssertEqual(ScriptCSV.rows(fromCSV: "a,b,c\n1,2,3"), [["a", "b", "c"], ["1", "2", "3"]])
        XCTAssertEqual(ScriptCSV.rows(fromCSV: "a,\"b,c\",\"d\"\"e\"\r\nf,g,h"), [["a", "b,c", "d\"e"], ["f", "g", "h"]])
        XCTAssertEqual(ScriptCSV.rows(fromCSV: "\"複数\n行\",x"), [["複数\n行", "x"]])
        XCTAssertEqual(ScriptCSV.rows(fromCSV: ""), [])
    }

    func testLinesNoHeader() {
        let csv = """
        霊夢,こんにちは,こんにちは(字幕)
        魔理沙,やあ,

        霊夢,字幕なしの行
        """
        XCTAssertEqual(ScriptCSV.lines(fromCSV: csv), [
            "霊夢: こんにちは | こんにちは(字幕)",
            "魔理沙: やあ",
            "霊夢: 字幕なしの行",
        ])
    }

    func testLinesWithHeaderReordered() {
        let csv = """
        字幕,名前,セリフ
        字幕A,霊夢,読みA
        ,魔理沙,読みB
        """
        XCTAssertEqual(ScriptCSV.lines(fromCSV: csv), [
            "霊夢: 読みA | 字幕A",
            "魔理沙: 読みB",
        ])
    }

    func testLinesNotesNamelessAndSingleColumn() {
        XCTAssertEqual(ScriptCSV.lines(fromCSV: "※ ここはメモ\n,名前なしのセリフ"), ["※ ここはメモ", "名前なしのセリフ"])
        XCTAssertEqual(ScriptCSV.lines(fromCSV: "セリフだけ1\nセリフだけ2"), ["セリフだけ1", "セリフだけ2"])
        XCTAssertEqual(ScriptCSV.lines(fromCSV: "\u{FEFF}霊夢,あ"), ["霊夢: あ"])   // BOM は落とす
    }

    func testLinesQuotedDialogueWithComma() {
        let csv = "霊夢,\"ねえ、聞いて\",字幕です"
        XCTAssertEqual(ScriptCSV.lines(fromCSV: csv), ["霊夢: ねえ、聞いて | 字幕です"])
    }
}
