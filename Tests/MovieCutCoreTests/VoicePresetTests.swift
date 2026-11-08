import XCTest
@testable import MovieCutCore

final class VoicePresetTests: XCTestCase {
    private func dec(_ s: String) throws -> VoicePresetCatalog { try VoicePresetCatalog.decode(Data(s.utf8)) }

    func testValid() throws {
        let c = try dec(#"{"schemaVersion":1,"presets":[{"id":"a","name":" 標準 ","note":"n","engine":"voicevox","speaker":3,"speed":1.2,"pitch":0.05,"intonation":1.1,"volume":1}]}"#)
        XCTAssertEqual(c.presets.count, 1)
        XCTAssertEqual(c.presets[0].name, "標準")
        XCTAssertEqual(c.presets[0].speaker, 3)
        XCTAssertEqual(c.presets[0].speed, 1.2)
    }
    func testMissingFieldsAndUnknownIgnored() throws {
        let c = try dec(#"{"presets":[{"name":"x","extra":1},{"id":"nn"},{"name":"bad","engine":"zzz"}],"future":true}"#)
        XCTAssertEqual(c.presets.count, 1)
        XCTAssertEqual(c.presets[0].engine, "voicevox")
        XCTAssertNil(c.presets[0].speed)
    }
    func testBadVersionAndGarbage() {
        XCTAssertThrowsError(try dec(#"{"schemaVersion":2,"presets":[]}"#)) { XCTAssertEqual($0 as? VoicePresetCatalog.Failure, .newerVersion(2)) }
        XCTAssertThrowsError(try dec("nope"))
        XCTAssertThrowsError(try dec(#"{"schemaVersion":1}"#))
    }
    func testOversize() {
        let big = Data(repeating: 0x20, count: VoicePresetCatalog.maxBytes + 1)
        XCTAssertThrowsError(try VoicePresetCatalog.decode(big)) { XCTAssertEqual($0 as? VoicePresetCatalog.Failure, .tooLarge) }
    }
    func testMaxCountAndNameLimit() throws {
        let items = (0..<250).map { #"{"id":"i\#($0)","name":"\#(String(repeating: "あ", count: 60))"}"# }.joined(separator: ",")
        let c = try dec(#"{"schemaVersion":1,"presets":[\#(items)]}"#)
        XCTAssertEqual(c.presets.count, 200)
        XCTAssertEqual(c.presets[0].name.count, 40)
    }
    func testClamping() throws {
        let c = try dec(#"{"presets":[{"name":"a","speed":99,"pitch":-5,"intonation":9,"volume":9},{"name":"b","engine":"aquestalk","speed":1}]}"#)
        XCTAssertEqual(c.presets[0].speed, 2)
        XCTAssertEqual(c.presets[0].pitch, -0.15)
        XCTAssertEqual(c.presets[0].intonation, 2)
        XCTAssertEqual(c.presets[0].volume, 2)
        XCTAssertEqual(c.presets[1].speed, 50)
    }
    func testApplyKeepsNonVoiceFields() throws {
        let p = try dec(#"{"presets":[{"name":"p","engine":"aquestalk","voice":"れいむ","speed":120}]}"#).presets[0]
        var ch = Character(); ch.name = "太郎"; ch.color = "#123456"; ch.x = 0.3
        let r = VoicePresetCatalog.applying(p, to: ch)
        XCTAssertEqual(r.name, "太郎"); XCTAssertEqual(r.color, "#123456"); XCTAssertEqual(r.x, 0.3); XCTAssertEqual(r.id, ch.id)
        XCTAssertEqual(r.engine, "aquestalk"); XCTAssertEqual(r.voice, "れいむ"); XCTAssertEqual(r.speed, 120)
    }
}
