import XCTest
import Foundation
@testable import MovieCutCore

/// 実際の audio_query 応答(「こんにちは、世界?」相当の抜粋)。pause_mora・is_interrogative・子音なしモーラ・未知キーを含む。
let sampleAudioQueryJSON = #"""
{
  "accent_phrases": [
    {
      "moras": [
        {"text":"コ","consonant":"k","consonant_length":0.0775,"vowel":"o","vowel_length":0.0953,"pitch":5.6},
        {"text":"ン","consonant":null,"consonant_length":null,"vowel":"N","vowel_length":0.0824,"pitch":5.8},
        {"text":"ニ","consonant":"n","consonant_length":0.0558,"vowel":"i","vowel_length":0.0735,"pitch":5.9},
        {"text":"チ","consonant":"ch","consonant_length":0.0601,"vowel":"i","vowel_length":0.0836,"pitch":5.7},
        {"text":"ワ","consonant":"w","consonant_length":0.0568,"vowel":"a","vowel_length":0.1107,"pitch":5.4}
      ],
      "accent": 5,
      "pause_mora": {"text":"、","consonant":null,"consonant_length":null,"vowel":"pau","vowel_length":0.4,"pitch":0.0},
      "is_interrogative": false
    },
    {
      "moras": [
        {"text":"セ","consonant":"s","consonant_length":0.07,"vowel":"e","vowel_length":0.09,"pitch":5.5},
        {"text":"カ","consonant":"k","consonant_length":0.06,"vowel":"a","vowel_length":0.1,"pitch":5.7},
        {"text":"イ","consonant":null,"consonant_length":null,"vowel":"i","vowel_length":0.12,"pitch":5.9}
      ],
      "accent": 0,
      "pause_mora": null,
      "is_interrogative": true
    }
  ],
  "speedScale": 1.0,
  "pitchScale": 0.0,
  "outputSamplingRate": 24000,
  "kana": "コンニチワ'、セカイ?"
}
"""#

final class VoicevoxAccentTests: XCTestCase {
    private func sampleQuery() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(sampleAudioQueryJSON.utf8)) as! [String: Any]
    }

    func testParseSample() throws {
        let phrases = try XCTUnwrap(VoicevoxAccent.phrases(fromQuery: try sampleQuery()))
        XCTAssertEqual(phrases.count, 2)
        XCTAssertEqual(phrases[0].moras.map(\.text), ["コ", "ン", "ニ", "チ", "ワ"])
        XCTAssertEqual(phrases[0].accent, 5)
        XCTAssertEqual(phrases[0].moras[0].consonant, "k")
        XCTAssertEqual(phrases[0].moras[0].consonantLength ?? 0, 0.0775, accuracy: 1e-9)
        XCTAssertNil(phrases[0].moras[1].consonant)
        XCTAssertEqual(phrases[0].pauseMora?.text, "、")
        XCTAssertEqual(phrases[0].pauseMora?.vowel, "pau")
        XCTAssertEqual(phrases[0].isInterrogative, false)
        XCTAssertNil(phrases[1].pauseMora)
        XCTAssertEqual(phrases[1].isInterrogative, true)
        XCTAssertEqual(phrases[1].accent, 0)
    }

    func testRoundTripPreservesEverything() throws {
        let phrases = try XCTUnwrap(VoicevoxAccent.phrases(fromQuery: try sampleQuery()))
        let obj = try VoicevoxAccent.jsonObject(from: phrases)
        let again = try XCTUnwrap(VoicevoxAccent.phrases(fromJSONObject: obj))
        XCTAssertEqual(again, phrases)
        // 再エンコード結果にも moras / accent / pause_mora / is_interrogative が残る
        let arr = try XCTUnwrap(obj as? [[String: Any]])
        XCTAssertEqual(Set(arr[0].keys), ["moras", "accent", "pause_mora", "is_interrogative"])
        XCTAssertEqual(arr[0]["accent"] as? Int, 5)
        XCTAssertEqual((arr[0]["moras"] as? [[String: Any]])?.count, 5)
        let pm = try XCTUnwrap(arr[0]["pause_mora"] as? [String: Any])
        XCTAssertEqual(pm["vowel"] as? String, "pau")
        // 元の JSON と意味が等しい(未知キーを持たない accent_phrases 部分)
        let orig = try XCTUnwrap(try sampleQuery()["accent_phrases"] as? [[String: Any]])
        let origPhrases = try XCTUnwrap(VoicevoxAccent.phrases(fromJSONObject: orig))
        XCTAssertEqual(origPhrases, phrases)
    }

    func testCodableSnakeCaseKeys() throws {
        let m = VoicevoxMora(text: "ア", vowel: "a", vowelLength: 0.1, pitch: 5)
        let data = try JSONEncoder().encode(VoicevoxAccentPhrase(moras: [m], accent: 1, pauseMora: m, isInterrogative: true))
        let s = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(s.contains("\"vowel_length\""))
        XCTAssertTrue(s.contains("\"pause_mora\""))
        XCTAssertTrue(s.contains("\"is_interrogative\""))
        XCTAssertFalse(s.contains("vowelLength"))
    }

    func testMissingOrBadAccentPhrases() {
        XCTAssertNil(VoicevoxAccent.phrases(fromQuery: [:]))
        XCTAssertNil(VoicevoxAccent.phrases(fromQuery: ["accent_phrases": "x"]))
        XCTAssertEqual(VoicevoxAccent.phrases(fromQuery: ["accent_phrases": [Any]()]), [])
    }

    func testClampAccent() {
        XCTAssertEqual(VoicevoxAccent.clampAccent(-3, moraCount: 5), 0)
        XCTAssertEqual(VoicevoxAccent.clampAccent(0, moraCount: 5), 0)
        XCTAssertEqual(VoicevoxAccent.clampAccent(3, moraCount: 5), 3)
        XCTAssertEqual(VoicevoxAccent.clampAccent(5, moraCount: 5), 5)
        XCTAssertEqual(VoicevoxAccent.clampAccent(9, moraCount: 5), 5)
        XCTAssertEqual(VoicevoxAccent.clampAccent(2, moraCount: 0), 0)
        XCTAssertEqual(VoicevoxAccent.clampAccent(2, moraCount: -1), 0)
    }

    func testSettingAccentAndClamped() throws {
        let phrases = try XCTUnwrap(VoicevoxAccent.phrases(fromQuery: try sampleQuery()))
        XCTAssertEqual(VoicevoxAccent.settingAccent(2, at: 1, in: phrases)[1].accent, 2)
        XCTAssertEqual(VoicevoxAccent.settingAccent(99, at: 1, in: phrases)[1].accent, 3)
        XCTAssertEqual(VoicevoxAccent.settingAccent(-1, at: 0, in: phrases)[0].accent, 0)
        XCTAssertEqual(VoicevoxAccent.settingAccent(1, at: 7, in: phrases), phrases)   // 範囲外は無変更
        var bad = phrases; bad[0].accent = 40; bad[1].accent = -2
        let c = VoicevoxAccent.clamped(bad)
        XCTAssertEqual(c.map(\.accent), [5, 0])
        XCTAssertEqual(VoicevoxAccent.moraCount(phrases), 8)
    }
}
