import XCTest
import Foundation
@testable import MovieCutCore

/// R2-1: モーラ単位の長さ・音高編集(スライダーの土台になる Core の純粋関数、保存、合成反映)。
/// 偽サーバとサンプル JSON は VoicevoxAccentSynthesisTests / VoicevoxAccentTests のものを共用する。
final class VoicevoxMoraSlidersTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vvmora-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        AccentFakeVoicevox.calls = []
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func sample() throws -> [VoicevoxAccentPhrase] {
        let q = try JSONSerialization.jsonObject(with: Data(sampleAudioQueryJSON.utf8)) as! [String: Any]
        return try XCTUnwrap(VoicevoxAccent.phrases(fromQuery: q))
    }

    // MARK: クランプ

    func testClampMoraValues() {
        XCTAssertEqual(VoicevoxAccent.clampVowelLength(0.09), 0.09, accuracy: 1e-12)
        XCTAssertEqual(VoicevoxAccent.clampVowelLength(0.0), VoicevoxAccent.vowelLengthRange.lowerBound)
        XCTAssertEqual(VoicevoxAccent.clampVowelLength(99), VoicevoxAccent.vowelLengthRange.upperBound)
        XCTAssertEqual(VoicevoxAccent.clampVowelLength(.nan), VoicevoxAccent.vowelLengthRange.lowerBound)
        XCTAssertEqual(VoicevoxAccent.clampConsonantLength(-1), 0)
        XCTAssertEqual(VoicevoxAccent.clampConsonantLength(99), VoicevoxAccent.consonantLengthRange.upperBound)
        XCTAssertEqual(VoicevoxAccent.clampMoraLength(0.0), VoicevoxAccent.moraLengthRange.lowerBound)
        XCTAssertEqual(VoicevoxAccent.clampMoraLength(99), VoicevoxAccent.moraLengthRange.upperBound)
        XCTAssertEqual(VoicevoxAccent.clampMoraPitch(5.6), 5.6, accuracy: 1e-12)
        XCTAssertEqual(VoicevoxAccent.clampMoraPitch(0), 0)   // 無声・ポーズの 0 は保つ
        XCTAssertEqual(VoicevoxAccent.clampMoraPitch(-2), 0)
        XCTAssertEqual(VoicevoxAccent.clampMoraPitch(99), VoicevoxAccent.moraPitchRange.upperBound)
        XCTAssertEqual(VoicevoxAccent.clampMoraPitch(.nan), 0)
    }

    /// 未調整互換: VOICEVOX が返した通常の値は、sanitized / clamped を通しても一切変わらない。
    func testSanitizedKeepsNativeValues() throws {
        let phrases = try sample()
        XCTAssertEqual(phrases.map { $0.withSanitizedMoras() }, phrases)
        XCTAssertEqual(VoicevoxAccent.clamped(phrases), phrases)
        for p in phrases { for m in p.moras { XCTAssertEqual(m.sanitized(), m) } }
        XCTAssertEqual(phrases[0].pauseMora?.sanitized(), phrases[0].pauseMora)
    }

    func testSanitizedClampsOutOfRangeMoras() throws {
        var phrases = try sample()
        phrases[0].moras[0].vowelLength = 99
        phrases[0].moras[0].consonantLength = -5
        phrases[0].moras[0].pitch = 42
        let s = phrases[0].withSanitizedMoras().moras[0]
        XCTAssertEqual(s.vowelLength, VoicevoxAccent.vowelLengthRange.upperBound)
        XCTAssertEqual(s.consonantLength, 0)
        XCTAssertEqual(s.pitch, VoicevoxAccent.moraPitchRange.upperBound)
        XCTAssertEqual(s.text, "コ")   // テキストや母音の種類は変えない
        XCTAssertEqual(s.vowel, "o")
    }

    // MARK: 音高の編集

    func testSettingMoraPitch() throws {
        let phrases = try sample()
        let edited = VoicevoxAccent.settingMoraPitch(6.5, phrase: 0, mora: 2, in: phrases)
        XCTAssertEqual(edited[0].moras[2].pitch, 6.5, accuracy: 1e-12)
        // 他のモーラ・句・核位置は不変
        XCTAssertEqual(edited[0].moras[0], phrases[0].moras[0])
        XCTAssertEqual(edited[0].moras[4], phrases[0].moras[4])
        XCTAssertEqual(edited[1], phrases[1])
        XCTAssertEqual(edited[0].accent, phrases[0].accent)
        // クランプ
        XCTAssertEqual(VoicevoxAccent.settingMoraPitch(99, phrase: 0, mora: 0, in: phrases)[0].moras[0].pitch,
                       VoicevoxAccent.moraPitchRange.upperBound)
        // 範囲外の index は無変更
        XCTAssertEqual(VoicevoxAccent.settingMoraPitch(6.5, phrase: 9, mora: 0, in: phrases), phrases)
        XCTAssertEqual(VoicevoxAccent.settingMoraPitch(6.5, phrase: 0, mora: 9, in: phrases), phrases)
        XCTAssertEqual(VoicevoxAccent.settingMoraPitch(6.5, phrase: -1, mora: 0, in: phrases), phrases)
    }

    // MARK: 長さの編集

    func testSettingMoraLengthPreservesRatio() throws {
        let phrases = try sample()
        let orig = phrases[0].moras[0]   // コ: 子音 0.0775 + 母音 0.0953 = 0.1728
        XCTAssertEqual(orig.totalLength, 0.1728, accuracy: 1e-9)
        let edited = VoicevoxAccent.settingMoraLength(orig.totalLength * 2, phrase: 0, mora: 0, in: phrases)
        let m = edited[0].moras[0]
        XCTAssertEqual(m.totalLength, orig.totalLength * 2, accuracy: 1e-9)
        XCTAssertEqual(m.consonantLength ?? 0, (orig.consonantLength ?? 0) * 2, accuracy: 1e-9)
        XCTAssertEqual(m.vowelLength, orig.vowelLength * 2, accuracy: 1e-9)
        XCTAssertEqual(m.pitch, orig.pitch)   // 音高は変えない
        // 半分に縮める場合も比率維持
        let half = VoicevoxAccent.settingMoraLength(orig.totalLength / 2, phrase: 0, mora: 0, in: phrases)[0].moras[0]
        XCTAssertEqual(half.totalLength, orig.totalLength / 2, accuracy: 1e-9)
        XCTAssertEqual(half.consonantLength ?? 0, (orig.consonantLength ?? 0) / 2, accuracy: 1e-9)
        // 他は不変・範囲外は無変更
        XCTAssertEqual(edited[0].moras[1], phrases[0].moras[1])
        XCTAssertEqual(VoicevoxAccent.settingMoraLength(0.3, phrase: 0, mora: 9, in: phrases), phrases)
    }

    func testSettingMoraLengthWithoutConsonant() throws {
        let phrases = try sample()
        let orig = phrases[0].moras[1]   // ン: 子音なし、母音 0.0824
        XCTAssertNil(orig.consonantLength)
        let m = VoicevoxAccent.settingMoraLength(0.2, phrase: 0, mora: 1, in: phrases)[0].moras[1]
        XCTAssertNil(m.consonantLength)   // 子音を捏造しない
        XCTAssertEqual(m.vowelLength, 0.2, accuracy: 1e-12)
        XCTAssertEqual(m.totalLength, 0.2, accuracy: 1e-12)
    }

    func testSettingMoraLengthClamps() throws {
        let phrases = try sample()
        let big = VoicevoxAccent.settingMoraLength(99, phrase: 0, mora: 0, in: phrases)[0].moras[0]
        XCTAssertEqual(big.totalLength, VoicevoxAccent.moraLengthRange.upperBound, accuracy: 1e-9)
        let small = VoicevoxAccent.settingMoraLength(0, phrase: 0, mora: 1, in: phrases)[0].moras[1]
        XCTAssertEqual(small.totalLength, VoicevoxAccent.moraLengthRange.lowerBound, accuracy: 1e-12)
    }

    func testSettingMoraVowelAndConsonantLength() throws {
        let phrases = try sample()
        let v = VoicevoxAccent.settingMoraVowelLength(0.3, phrase: 0, mora: 0, in: phrases)[0].moras[0]
        XCTAssertEqual(v.vowelLength, 0.3, accuracy: 1e-12)
        XCTAssertEqual(v.consonantLength, phrases[0].moras[0].consonantLength)   // 子音は不変
        let c = VoicevoxAccent.settingMoraConsonantLength(0.02, phrase: 0, mora: 0, in: phrases)[0].moras[0]
        XCTAssertEqual(c.consonantLength ?? -1, 0.02, accuracy: 1e-12)
        XCTAssertEqual(c.vowelLength, phrases[0].moras[0].vowelLength)   // 母音は不変
        // 子音が無いモーラへの子音長さ指定は無変更
        XCTAssertEqual(VoicevoxAccent.settingMoraConsonantLength(0.05, phrase: 0, mora: 1, in: phrases), phrases)
    }

    func testMoraAccessor() throws {
        let phrases = try sample()
        XCTAssertEqual(VoicevoxAccent.mora(phrase: 1, mora: 2, in: phrases)?.text, "イ")
        XCTAssertNil(VoicevoxAccent.mora(phrase: 5, mora: 0, in: phrases))
        XCTAssertNil(VoicevoxAccent.mora(phrase: 0, mora: 5, in: phrases))
    }

    // MARK: 保存・復元

    func testEditedMoraValuesRoundTrip() throws {
        var edited = try sample()
        edited = VoicevoxAccent.settingMoraPitch(6.5, phrase: 0, mora: 0, in: edited)
        edited = VoicevoxAccent.settingMoraLength(0.3, phrase: 1, mora: 1, in: edited)
        edited = VoicevoxAccent.settingMoraVowelLength(0.25, phrase: 0, mora: 4, in: edited)
        // 型のままのラウンドトリップ
        let data = try JSONEncoder().encode(edited)
        XCTAssertEqual(try JSONDecoder().decode([VoicevoxAccentPhrase].self, from: data), edited)
        let s = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(s.contains("\"pitch\":6.5"))
        XCTAssertTrue(s.contains("\"vowel_length\""))
        XCTAssertTrue(s.contains("\"consonant_length\""))
        // Clip(プロジェクト保存形式)のラウンドトリップでもモーラ値が保たれる
        var clip = Clip(); clip.voicevoxAccent = edited
        let back = try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(clip))
        XCTAssertEqual(back.voicevoxAccent, edited)
        XCTAssertEqual(back.voicevoxAccent?[0].moras[0].pitch, 6.5)
        XCTAssertEqual(back.voicevoxAccent?[1].moras[1].totalLength ?? -1, 0.3, accuracy: 1e-9)
        // 編集すると安定 JSON(キャッシュキーの要素)が変わる
        XCTAssertNotEqual(VoicevoxAccent.stableJSON(edited), VoicevoxAccent.stableJSON(try sample()))
    }

    // MARK: 合成への反映(内蔵・プラグイン両経路)

    private static let base = "http://fake.local:50021"
    private static let policy = VoiceEndpointPolicy(allowRemote: true, allowedHosts: ["fake.local"])

    func testSynthesisBodyReflectsMoraEditsBuiltinAndPlugin() async throws {
        var edited = try sample()
        edited = VoicevoxAccent.settingMoraPitch(6.5, phrase: 0, mora: 0, in: edited)
        edited = VoicevoxAccent.settingMoraLength(0.3456, phrase: 0, mora: 0, in: edited)
        edited = VoicevoxAccent.settingMoraVowelLength(0.25, phrase: 1, mora: 2, in: edited)

        let builtin = VoicevoxClient(baseURL: Self.base, cache: VoiceCache(directory: tmp.appendingPathComponent("b")), session: AccentFakeVoicevox.session(), policy: Self.policy)
        let plugin = VoicevoxPluginClient(baseURL: Self.base, cache: VoiceCache(directory: tmp.appendingPathComponent("p")), session: AccentFakeVoicevox.session(), policy: Self.policy)
        let family = VoicevoxFamilyPluginClient(spec: VoicevoxFamily.spec(forEngine: "coeiroink")!, baseURL: Self.base, cache: VoiceCache(directory: tmp.appendingPathComponent("f")), session: AccentFakeVoicevox.session(), policy: Self.policy)

        for (name, synth) in [
            ("builtin", { try await builtin.synthesize(text: "こんにちは", speaker: 3, accentPhrases: edited) }),
            ("plugin", { try await plugin.synthesize(text: "こんにちは", speaker: 3, accentPhrases: edited) }),
            ("family", { try await family.synthesize(text: "こんにちは", speaker: 3, accentPhrases: edited) }),
        ] as [(String, () async throws -> URL)] {
            AccentFakeVoicevox.calls = []
            _ = try await synth()
            let call = try XCTUnwrap(AccentFakeVoicevox.calls.last, name)
            XCTAssertEqual(call.path, "/synthesis", name)
            let body = try JSONSerialization.jsonObject(with: try XCTUnwrap(call.body)) as! [String: Any]
            let sent = try XCTUnwrap(VoicevoxAccent.phrases(fromJSONObject: try XCTUnwrap(body["accent_phrases"])), name)
            XCTAssertEqual(sent, edited, name)
            XCTAssertEqual(sent[0].moras[0].pitch, 6.5, accuracy: 1e-12, name)
            XCTAssertEqual(sent[0].moras[0].totalLength, 0.3456, accuracy: 1e-9, name)
            XCTAssertEqual(sent[1].moras[2].vowelLength, 0.25, accuracy: 1e-12, name)
        }
    }

    func testCacheKeyChangesWithMoraLengthOnly() async throws {
        let plain = try sample()
        let lengthEdited = VoicevoxAccent.settingMoraLength(0.3, phrase: 0, mora: 0, in: plain)
        XCTAssertNotEqual(VoicevoxAccent.stableJSON(lengthEdited), VoicevoxAccent.stableJSON(plain))
        let client = VoicevoxClient(baseURL: Self.base, cache: VoiceCache(directory: tmp.appendingPathComponent("k")), session: AccentFakeVoicevox.session(), policy: Self.policy)
        let u1 = try await client.synthesize(text: "あ", speaker: 3, accentPhrases: plain)
        let u2 = try await client.synthesize(text: "あ", speaker: 3, accentPhrases: lengthEdited)
        XCTAssertNotEqual(u1, u2)
        // 同じ編集内容はキャッシュに当たる(再通信なし)
        let calls = AccentFakeVoicevox.calls.count
        let u3 = try await client.synthesize(text: "あ", speaker: 3, accentPhrases: lengthEdited)
        XCTAssertEqual(u3, u2)
        XCTAssertEqual(AccentFakeVoicevox.calls.count, calls)
    }

    // MARK: 再合成経路(regenerateVoice)

    func testRegenerateVoicePassesMoraEditsToProvider() async throws {
        var edited = try sample()
        edited = VoicevoxAccent.settingMoraPitch(4.5, phrase: 0, mora: 1, in: edited)
        edited = VoicevoxAccent.settingMoraLength(0.05, phrase: 0, mora: 1, in: edited)
        let p = Project.new()
        var clip = Clip()
        clip.type = .voice; clip.charId = p.characters[0].id; clip.text = "こんにちは"; clip.duration = 9; clip.src = "/old.wav"
        clip.voicevoxAccent = edited
        let mock = MoraSliderMockVoice()
        try await ScriptTimeline.regenerateVoice(clip: &clip, project: p, provider: mock)
        XCTAssertEqual(mock.normal, [])
        XCTAssertEqual(mock.accent.count, 1)
        XCTAssertEqual(mock.accent[0].phrases, edited)
        XCTAssertEqual(mock.accent[0].phrases[0].moras[1].pitch, 4.5, accuracy: 1e-12)
        XCTAssertEqual(clip.voicevoxAccent, edited)   // 保存値は再合成で書き換わらない
    }
}

private final class MoraSliderMockVoice: VoicevoxAccentProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _normal: [String] = []
    private var _accent: [(text: String, phrases: [VoicevoxAccentPhrase])] = []
    var normal: [String] { lock.withLock { _normal } }
    var accent: [(text: String, phrases: [VoicevoxAccentPhrase])] { lock.withLock { _accent } }
    private func result() -> VoiceResult { VoiceResult(url: URL(fileURLWithPath: "/tmp/mock-\(UUID().uuidString).wav"), duration: 1.0) }
    func synthesize(character: Character, text: String, in directory: URL) async throws -> VoiceResult {
        lock.withLock { _normal.append(text) }; return result()
    }
    func synthesizeWithAccent(character: Character, text: String, accentPhrases: [VoicevoxAccentPhrase], in directory: URL) async throws -> VoiceResult {
        lock.withLock { _accent.append((text, accentPhrases)) }; return result()
    }
}
