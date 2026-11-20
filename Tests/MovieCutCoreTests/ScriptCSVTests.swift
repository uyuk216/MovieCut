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
        キャラ1,こんにちは,こんにちは(字幕)
        キャラ2,やあ,

        キャラ1,字幕なしの行
        """
        XCTAssertEqual(ScriptCSV.lines(fromCSV: csv), [
            "キャラ1: こんにちは | こんにちは(字幕)",
            "キャラ2: やあ",
            "キャラ1: 字幕なしの行",
        ])
    }

    func testLinesWithHeaderReordered() {
        let csv = """
        字幕,名前,セリフ
        字幕A,キャラ1,読みA
        ,キャラ2,読みB
        """
        XCTAssertEqual(ScriptCSV.lines(fromCSV: csv), [
            "キャラ1: 読みA | 字幕A",
            "キャラ2: 読みB",
        ])
    }

    func testLinesNotesNamelessAndSingleColumn() {
        XCTAssertEqual(ScriptCSV.lines(fromCSV: "※ ここはメモ\n,名前なしのセリフ"), ["※ ここはメモ", "名前なしのセリフ"])
        XCTAssertEqual(ScriptCSV.lines(fromCSV: "セリフだけ1\nセリフだけ2"), ["セリフだけ1", "セリフだけ2"])
        XCTAssertEqual(ScriptCSV.lines(fromCSV: "\u{FEFF}キャラ1,あ"), ["キャラ1: あ"])   // BOM は落とす
    }

    func testLinesQuotedDialogueWithComma() {
        let csv = "キャラ1,\"ねえ、聞いて\",字幕です"
        XCTAssertEqual(ScriptCSV.lines(fromCSV: csv), ["キャラ1: ねえ、聞いて | 字幕です"])
    }
}
