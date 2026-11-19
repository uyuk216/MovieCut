import XCTest
@testable import MovieCutCore

/// 放送・配信用字幕(SCC / EBU-STL)の変換テスト。仕様の根拠は docs/放送・配信用字幕形式.md。
final class BroadcastSubtitleTests: XCTestCase {
    private func cue(_ s: Double, _ e: Double, _ t: String) -> SubtitleCue { SubtitleCue(start: s, end: e, text: t) }

    /// SCC のデータ行を (タイムコード, ワード列) に割る。
    private func sccLines(_ text: String) -> [(String, [String])] {
        text.components(separatedBy: "\n").compactMap { line in
            let parts = line.components(separatedBy: "\t")
            guard parts.count == 2, !parts[0].isEmpty else { return nil }
            return (parts[0], parts[1].components(separatedBy: " "))
        }
    }

    // MARK: SCC 時刻(ドロップフレーム)

    func testSCCDropFrameTimecode() {
        XCTAssertEqual(SCCExporter.timecode(frame: 0, dropFrame: true), "00:00:00;00")
        XCTAssertEqual(SCCExporter.timecode(frame: 1798, dropFrame: true), "00:00:59;28")
        // 1 分の境目では番号 00/01 を飛ばす
        XCTAssertEqual(SCCExporter.timecode(frame: 1800, dropFrame: true), "00:01:00;02")
        // 10 分ごとは飛ばさない
        XCTAssertEqual(SCCExporter.timecode(frame: 17982, dropFrame: true), "00:10:00;00")
        XCTAssertEqual(SCCExporter.timecode(frame: 1800, dropFrame: false), "00:01:00:00")
        XCTAssertEqual(SCCExporter.frameIndex(at: 1.0), 30, "29.97fps で 1 秒 = 30 フレーム目(四捨五入)")
        XCTAssertEqual(SCCExporter.frameIndex(at: 0), 0)
        XCTAssertEqual(SCCExporter.frameIndex(at: -5), 0)
    }

    func testSCCParityIsOddForAllBytes() {
        XCTAssertEqual(SCCExporter.withParity(0x48), 0xC8, "H は 1 が偶数個なのでパリティを立てる")
        XCTAssertEqual(SCCExporter.withParity(0x45), 0x45, "E は奇数個なのでそのまま")
        XCTAssertEqual(SCCExporter.withParity(0x00), 0x80)
        let (text, _) = SCCExporter.export([cue(5, 8, "HELLO WORLD"), cue(10, 13, "Café ♪")])
        for (_, words) in sccLines(text) {
            for w in words {
                let v = UInt16(w, radix: 16)!
                XCTAssertEqual((v >> 8).nonzeroBitCount % 2, 1, "上位バイトのパリティ: \(w)")
                XCTAssertEqual((v & 0xFF).nonzeroBitCount % 2, 1, "下位バイトのパリティ: \(w)")
            }
        }
    }

    func testSCCHeaderAndKnownEncodingOfHello() {
        let (text, warnings) = SCCExporter.export([cue(5, 8, "HELLO")])
        XCTAssertTrue(warnings.isEmpty, "\(warnings)")
        XCTAssertTrue(text.hasPrefix("Scenarist_SCC V1.0\n\n"))
        let lines = sccLines(text)
        XCTAssertEqual(lines.count, 2, "読み込み行 + 消去行")
        // "HELLO" の 608 バイト列は c8 45 4c 4c 4f(+詰め物 80) = ワード c845 4c4c 4f80
        XCTAssertTrue(lines[0].1.contains("c845"), "\(lines[0].1)")
        XCTAssertTrue(lines[0].1.contains("4c4c"), "\(lines[0].1)")
        XCTAssertTrue(lines[0].1.contains("4f80"), "\(lines[0].1)")
        // 先頭は ENM/RCL の二重送信、末尾は EOC の二重送信
        XCTAssertEqual(Array(lines[0].1.prefix(4)), ["94ae", "94ae", "9420", "9420"])
        XCTAssertEqual(Array(lines[0].1.suffix(2)), ["942f", "942f"])
        // 消去行は EDM の二重送信のみで、終了(8 秒 = フレーム 240)のタイムコード
        XCTAssertEqual(lines[1].1, ["942c", "942c"])
        XCTAssertEqual(lines[1].0, SCCExporter.timecode(frame: SCCExporter.frameIndex(at: 8), dropFrame: true))
    }

    func testSCCBasicOverrideAndSpecialCharacters() {
        // á は基本文字 0x2A(パリティ込みでも 2a)、詰め物と対で 2a80
        let (t1, _) = SCCExporter.export([cue(5, 8, "á")])
        XCTAssertTrue(sccLines(t1)[0].1.contains("2a80"), "\(sccLines(t1))")
        // ♪ は特殊文字 9137
        let (t2, _) = SCCExporter.export([cue(5, 8, "♪")])
        XCTAssertTrue(sccLines(t2)[0].1.contains("9137"), "\(sccLines(t2))")
    }

    func testSCCPacTable() {
        // 行 15・桁 0 の PAC は 9470、行 15・桁 20 は 947a、行 1・桁 0 は 9150 相当(生では 11 50)
        func rawHex(_ p: (UInt8, UInt8)) -> String {
            String(format: "%02x%02x", SCCExporter.withParity(p.0), SCCExporter.withParity(p.1))
        }
        XCTAssertEqual(rawHex(SCCExporter.pac(row: 15, indent: 0)), "9470")
        XCTAssertEqual(rawHex(SCCExporter.pac(row: 15, indent: 20)), "947a")
        XCTAssertEqual(rawHex(SCCExporter.pac(row: 14, indent: 0)), "94d0")
        XCTAssertEqual(rawHex(SCCExporter.pac(row: 11, indent: 0)), "10d0")
        XCTAssertEqual(rawHex(SCCExporter.pac(row: 12, indent: 0)), "13d0")
    }

    func testSCCWrapsAt32ColumnsAndUsesTwoRows() {
        let (text, _) = SCCExporter.export([cue(5, 10, "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")]) // 40 字
        let words = sccLines(text)[0].1
        // 32 桁で折れて 2 行になる = PAC が 2 行ぶん(二重送信で 4 ワード中に行 14/15)
        let pacs = words.filter { $0.hasPrefix("94") || $0.hasPrefix("10") || $0.hasPrefix("13") }
        XCTAssertTrue(pacs.count >= 4, "\(words)")
        XCTAssertTrue(words.contains("94d0") || words.contains("9452") || words.contains("9454"), "行 14 の PAC がある: \(words)")
    }

    func testSCCUnrepresentableJapaneseBecomesQuestionMarkWithWarning() {
        let (text, warnings) = SCCExporter.export([cue(5, 8, "こんにちは")])
        XCTAssertFalse(warnings.isEmpty)
        XCTAssertTrue(warnings[0].contains("? に置き換え"), "\(warnings)")
        // '?' は 0x3F → パリティで 0xBF。5 文字 + 詰め物 = ワード bfbf bfbf bf80
        let words = sccLines(text)[0].1
        XCTAssertTrue(words.contains("bfbf"), "\(words)")
        XCTAssertTrue(words.contains("bf80"), "\(words)")
    }

    func testSCCLongCueSplitsIntoMultipleCaptions() {
        let long = (1...6).map { "LINE NUMBER \($0) ABCDEFGHIJ" }.joined(separator: "\n") // 6 行
        let (text, warnings) = SCCExporter.export([cue(5, 20, long)])
        XCTAssertTrue(warnings.contains { $0.contains("分割") }, "\(warnings)")
        // 4 行 + 2 行に分かれて読み込み行が 2 つ出る。消去は最後の字幕の分だけ
        // (途中の字幕は次の表示の入れ替えで消える)なので、行は合計 3 行。
        XCTAssertEqual(sccLines(text).count, 3, "\(sccLines(text).map { $0.0 })")
    }

    func testSCCEmptyAndInvalidCuesAreSkipped() {
        let (text, warnings) = SCCExporter.export([cue(1, 1, "長さ0"), cue(2, 3, "  ")])
        XCTAssertEqual(text, "Scenarist_SCC V1.0\n\n")
        XCTAssertTrue(warnings.isEmpty)
    }

    // MARK: EBU-STL

    private func opt(_ fr: EBUSTLFrameRate = .fps25) -> EBUSTLOptions {
        EBUSTLOptions(frameRate: fr, programmeTitle: "Test", languageCode: "09", creationDateCode: "261119")
    }

    func testSTLStructureAndGSIFields() {
        let (data, warnings) = EBUSTLExporter.export([cue(1, 2, "Hello"), cue(3, 4, "World")], options: opt())
        XCTAssertTrue(warnings.isEmpty, "\(warnings)")
        XCTAssertEqual(data.count, 1024 + 128 * 2)
        let b = [UInt8](data)
        XCTAssertEqual(String(bytes: b[0..<3], encoding: .ascii), "437") // CPN
        XCTAssertEqual(String(bytes: b[3..<11], encoding: .ascii), "STL25.01") // DFC
        XCTAssertEqual(String(bytes: b[11..<12], encoding: .ascii), "0") // DSC(オープン字幕)
        XCTAssertEqual(String(bytes: b[12..<14], encoding: .ascii), "00") // CCT(ISO 6937)
        XCTAssertEqual(String(bytes: b[14..<16], encoding: .ascii), "09") // LC
        XCTAssertEqual(String(bytes: b[238..<243], encoding: .ascii), "00002") // TNB
        XCTAssertEqual(String(bytes: b[243..<248], encoding: .ascii), "00002") // TNS
        XCTAssertEqual(String(bytes: b[251..<253], encoding: .ascii), "40") // MNC
        // 1 件目の TTI: TCI = 25 フレーム(1 秒) = 00:00:01:00、TCO = 50 フレーム = 00:00:02:00
        XCTAssertEqual(Array(b[1024 + 5..<1024 + 9]), [0, 0, 1, 0])
        XCTAssertEqual(Array(b[1024 + 9..<1024 + 13]), [0, 0, 2, 0])
        XCTAssertEqual(b[1024 + 3], 0xFF, "EBN(最終ブロック)")
        XCTAssertEqual(b[1024 + 14], 0x02, "JC(中央)")
        // テキストの後ろは 0x8F で埋める
        XCTAssertEqual(b[1024 + 16 + 5], 0x8F)
    }

    func testSTLFrameRate30() {
        let (data, _) = EBUSTLExporter.export([cue(1, 2, "Hi")], options: opt(.fps30))
        let b = [UInt8](data)
        XCTAssertEqual(String(bytes: b[3..<11], encoding: .ascii), "STL30.01")
        XCTAssertEqual(Array(b[1024 + 5..<1024 + 9]), [0, 0, 1, 0], "30fps でも 1 秒 = フレーム 30 → 00:00:01:00")
        XCTAssertEqual(EBUSTLExporter.parse(data), [cue(1, 2, "Hi")])
    }

    func testSTLRoundTripWithDiacritics() {
        let cues = [cue(0, 1, "Café"), cue(1.04, 2, "Äpfel und Öl"), cue(2.04, 3.52, "naïve façade\nsecond line")]
        let (data, warnings) = EBUSTLExporter.export(cues, options: opt())
        XCTAssertTrue(warnings.isEmpty, "\(warnings)")
        XCTAssertEqual(EBUSTLExporter.parse(data), cues)
    }

    func testSTLJapaneseBecomesQuestionMarkWithWarning() {
        let (data, warnings) = EBUSTLExporter.export([cue(0, 1, "こんにちは")], options: opt())
        XCTAssertFalse(warnings.isEmpty)
        XCTAssertEqual(EBUSTLExporter.parse(data), [cue(0, 1, "?????")])
    }

    func testSTLLongTextUsesExtensionBlocksAndRoundTrips() {
        let line = "abcdefghijklmnopqrstuvwxyz012345678" // 35 字
        let long = [line, line, line, line].joined(separator: "\n") // 143 バイト → 112 バイト超で拡張ブロック
        let (data, _) = EBUSTLExporter.export([cue(0, 10, long)], options: opt())
        let b = [UInt8](data)
        XCTAssertEqual(String(bytes: b[238..<243], encoding: .ascii), "00002", "TNB は拡張含むブロック数")
        XCTAssertEqual(String(bytes: b[243..<248], encoding: .ascii), "00001", "TNS は字幕数")
        XCTAssertEqual(b[1024 + 3], 0x00, "先頭ブロックの EBN は 0")
        XCTAssertEqual(b[1024 + 128 + 3], 0xFF, "拡張ブロックの EBN は FF(最終)")
        XCTAssertEqual(EBUSTLExporter.parse(data), [cue(0, 10, long)])
    }

    func testSTLParseRejectsNonSTL() {
        XCTAssertNil(EBUSTLExporter.parse(Data()))
        XCTAssertNil(EBUSTLExporter.parse(Data(repeating: 0, count: 1024)))
        XCTAssertNil(EBUSTLExporter.parse(Data(repeating: 0, count: 500)))
    }

    func testSTLEmptyCuesProduceHeaderOnly() {
        let (data, _) = EBUSTLExporter.export([], options: opt())
        XCTAssertEqual(data.count, 1024)
        XCTAssertEqual(EBUSTLExporter.parse(data), [])
    }
}
