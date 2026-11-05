import XCTest
@testable import MovieCutCore

final class LipSyncTests: XCTestCase {
    // MARK: 読み → 口の形(表テスト)

    func testMoraTable() {
        let table: [(String, [Viseme])] = [
            ("こんにちは", [.o, .closed, .i, .i, .a]),            // ん = 閉じる
            ("ありがとう", [.a, .i, .a, .o, .u]),
            ("コーヒー", [.o, .o, .i, .i]),                        // ー = 直前の母音の繰り返し
            ("きょう", [.o, .u]),                                   // 拗音は 1 拍で、ゃゅょの母音
            ("ちっちゃい", [.i, .closed, .a, .i]),                   // っ = 閉じる(1 拍)
            ("ふぁいと", [.a, .i, .o]),                             // 小さい ぁ は母音そのもの
            ("あ、い。う", [.a, .closed, .i, .closed, .u]),          // 句読点 = 間
            ("[笑顔]えお", [.e, .o]),                               // 表情タグは読まない
            ("んー", []),                                            // 母音が無い
            ("", []),
        ]
        for (text, want) in table { XCTAssertEqual(LipSync.moras(of: text), want, text) }
    }

    func testKanjiReadingUsesTokenizer() {
        // 漢字は読み(CFStringTokenizer)を通して母音にする
        XCTAssertEqual(LipSync.moras(of: "学校"), [.a, .closed, .o, .u], "がっこう")
        XCTAssertEqual(LipSync.moras(of: "日本語").first, .i)
    }

    // MARK: 拍 × 音量 → コマ(タイミング)

    func testSilenceStaysClosedAndMorasFollowOrder() {
        // 無音 10 コマ → 一定音量 40 コマ → 無音 10 コマ。4 拍が 10 コマずつ
        let env: [Float] = Array(repeating: 0, count: 10) + Array(repeating: 0.1, count: 40) + Array(repeating: 0, count: 10)
        let f = LipSync.frames(moras: [.a, .i, .u, .e], envelope: env)!
        XCTAssertEqual(f.count, 60)
        XCTAssertTrue(f[0..<10].allSatisfy { $0 == .closed })
        XCTAssertTrue(f[50..<60].allSatisfy { $0 == .closed })
        XCTAssertTrue(f[10..<20].allSatisfy { $0 == .a })
        XCTAssertTrue(f[20..<30].allSatisfy { $0 == .i })
        XCTAssertTrue(f[30..<40].allSatisfy { $0 == .u })
        XCTAssertTrue(f[40..<50].allSatisfy { $0 == .e })
    }

    func testLoudPartAdvancesFaster() {
        // 前半が 3 倍の音量: 音量の積算で配るので、前半に多くの拍が来る
        let env: [Float] = Array(repeating: 0.3, count: 20) + Array(repeating: 0.1, count: 20)
        let f = LipSync.frames(moras: [.a, .i, .u, .e], envelope: env)!
        XCTAssertEqual(f[0], .a); XCTAssertEqual(f[39], .e)
        // 前半 20 コマ(積算 6 / 全体 8)に 3 拍分が入る
        XCTAssertEqual(Set(f[0..<20]), [.a, .i, .u])
    }

    func testDeterministicAndRangeLimited() {
        let env: [Float] = (0..<120).map { i in i < 30 || i >= 90 ? 0.1 : 0 }
        let a = LipSync.frames(moras: [.a, .o], envelope: env, range: 0..<60)!
        XCTAssertEqual(a, LipSync.frames(moras: [.a, .o], envelope: env, range: 0..<60))
        XCTAssertTrue(a[60...].allSatisfy { $0 == .closed }, "使う範囲の外は閉じる")
        XCTAssertEqual(a[0], .a); XCTAssertEqual(a[29], .o)
        XCTAssertNil(LipSync.frames(moras: [], envelope: env))
    }

    // MARK: 保存形式

    func testVowelImagesAreOmittedWhenUnsetAndRoundTrip() throws {
        let plain = String(decoding: try JSONEncoder().encode(Character()), as: UTF8.self)
        XCTAssertFalse(plain.contains("imgVowels"))
        var c = Character(); c.imgVowels = ["a": "/a/a.png", "o": "/a/o.png"]
        let back = try JSONDecoder().decode(Character.self, from: try JSONEncoder().encode(c))
        XCTAssertEqual(back, c)
        let empty = try JSONDecoder().decode(Character.self, from: Data(#"{"name":"A","imgVowels":{}}"#.utf8))
        XCTAssertNil(empty.imgVowels)
    }
}
