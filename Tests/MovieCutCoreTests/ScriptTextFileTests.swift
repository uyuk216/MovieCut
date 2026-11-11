import XCTest
@testable import MovieCutCore

/// 台本の文字をプロジェクトに保存する(`Project.scriptText`)。空のときは書かない = 古いファイルとバイト一致。
final class ScriptTextFileTests: XCTestCase {
    func testEmptyScriptIsOmittedFromTheFile() throws {
        let json = String(decoding: try Project.new().encoded(), as: UTF8.self)
        XCTAssertFalse(json.contains("scriptText"))
    }

    func testScriptRoundTripsIncludingNewlinesAndJapanese() throws {
        var p = Project.new()
        p.scriptText = "キャラ1: こんにちは！\nキャラ2: よろしく | 字幕\n\"引用\" と \\ と 絵文字🙂"
        let back = try Project.decode(from: p.encoded())
        XCTAssertEqual(back.scriptText, p.scriptText)
        XCTAssertNil(back.extra["scriptText"], "既知のキーなので extra には入らない")
    }

    func testOldFileWithoutTheKeyLoadsWithEmptyScript() throws {
        let back = try Project.decode(from: Data(#"{"width":1280,"height":720}"#.utf8))
        XCTAssertEqual(back.scriptText, "")
    }

    func testWrongTypeIsKeptAsExtraNotDropped() throws {
        let back = try Project.decode(from: Data(#"{"scriptText":123}"#.utf8))
        XCTAssertEqual(back.scriptText, "")
        XCTAssertEqual(back.extra["scriptText"], .number(123))
        XCTAssertTrue(String(decoding: try back.encoded(), as: UTF8.self).contains("\"scriptText\" : 123"))
    }

    func testAnOlderAppKeepsTheKeyAsUnknownAndWritesItBack() throws {
        // 古い版 = scriptText を知らない版。同じ仕組み(知らないキーの保持)で、中身が失われないことの確認
        let json = Data(#"{"width":1280,"height":720,"futureKey":"x"}"#.utf8)
        let p = try Project.decode(from: json)
        XCTAssertEqual(p.extra["futureKey"], .string("x"))
        XCTAssertTrue(String(decoding: try p.encoded(), as: UTF8.self).contains("futureKey"))
    }
}
