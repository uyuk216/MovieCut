import XCTest
@testable import MovieCutCore

/// R3-2: アプリ配線を自動判定プロバイダ(`CoeiroinkPlugin.makeAutoProvider`)へ切り替えた前提の検証。
/// モックは R3-1 の `FakeCoeiroinkV2Server`(v2 確定形式 + v1 互換応答)をそのまま使う。
/// 確認する利用者向け挙動:
/// - v1 エンジンしか無い環境では、従来の v1 プロバイダへ委譲され、リクエスト列・合成結果が
///   従来と一致する(先頭に判定の GET /v1/engine_info が 1 回増えるだけ)。
/// - v2 エンジンがある環境では v2 合成へ流れる。
/// - エンジン未起動時は、従来どおり v1 側の案内文で止まる(v2 用の文面にはならない)。
/// - アクセント句つき合成は v1 環境で従来どおり差し替え合成へ委譲され、v2 環境では通常合成に落ちる。
final class CoeiroinkAutoWiringTests: XCTestCase {
    var tmp: URL!
    static let policy = VoiceEndpointPolicy(allowRemote: true, allowedHosts: ["fake.local"])
    static let fakeBase = "http://fake.local:50032"

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("coeiro-wiring-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        FakeCoeiroinkV2Server.reset()
        let wavURL = tmp.appendingPathComponent("tone.wav")
        try ToneVoiceProvider.writeTone(to: wavURL, duration: 0.4, frequency: 440)
        FakeCoeiroinkV2Server.wav = try Data(contentsOf: wavURL)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func freshCache(_ name: String) -> VoiceCache { VoiceCache(directory: tmp.appendingPathComponent(name)) }
    private func autoProvider(cacheName: String) -> CoeiroinkAutoProvider {
        CoeiroinkPlugin.makeAutoProvider(baseURL: Self.fakeBase, cache: freshCache(cacheName), session: FakeCoeiroinkV2Server.session(), policy: Self.policy)
    }
    private func character(speaker: Int? = 2) -> Character {
        var c = Character(); c.engine = "coeiroink"; c.speaker = speaker; c.speed = 1.2; c.pitch = 0.1; c.intonation = 1.1
        return c
    }
    private func samplePhrases() -> [VoicevoxAccentPhrase] {
        [VoicevoxAccentPhrase(moras: [VoicevoxAccentMora(text: "コ", consonant: "k", vowel: "o", vowelLength: 0.1, pitch: 5.5),
                                      VoicevoxAccentMora(text: "ン", vowel: "N", vowelLength: 0.1, pitch: 5.0)], accent: 1)]
    }

    // 1: v1 委譲は従来の v1 プロバイダと一致する(判定の 1 回だけ先行し、以降のリクエスト列と合成ボディが同一)
    func testV1DelegationMatchesDirectV1ExceptProbe() async throws {
        FakeCoeiroinkV2Server.engineInfoStatus = 404   // v2 は応答しない = v1 エンジンだけの環境
        let direct = CoeiroinkPlugin.makeProvider(baseURL: Self.fakeBase, cache: freshCache("direct"), session: FakeCoeiroinkV2Server.session(), policy: Self.policy)
        let r1 = try await direct.synthesize(character: character(), text: "配線確認", in: tmp)
        let directCalls = FakeCoeiroinkV2Server.calls
        XCTAssertEqual(directCalls.map(\.path), ["/version", "/audio_query", "/synthesis"], "\(directCalls.map(\.path))")

        FakeCoeiroinkV2Server.reset()
        FakeCoeiroinkV2Server.engineInfoStatus = 404
        let auto = autoProvider(cacheName: "auto")
        let r2 = try await auto.synthesize(character: character(), text: "配線確認", in: tmp)
        let autoCalls = FakeCoeiroinkV2Server.calls
        XCTAssertEqual(autoCalls.map(\.path), ["/v1/engine_info"] + directCalls.map(\.path), "\(autoCalls.map(\.path))")
        // v1 の /synthesis へ送るボディも従来と同一(パラメータ変換が変わっていないこと)
        let directBody = try JSONSerialization.jsonObject(with: try XCTUnwrap(directCalls.last?.body)) as! NSDictionary
        let autoBody = try JSONSerialization.jsonObject(with: try XCTUnwrap(autoCalls.last?.body)) as! NSDictionary
        XCTAssertEqual(autoBody, directBody)
        XCTAssertEqual(r2.duration, r1.duration, accuracy: 0.001)
        XCTAssertEqual(try Data(contentsOf: r2.url), try Data(contentsOf: r1.url))
    }

    // 2: v2 エンジンがある環境では v2 合成へ流れる(v1 の audio_query / synthesis は呼ばない)
    func testV2EngineRoutesToV2Synthesis() async throws {
        let auto = autoProvider(cacheName: "v2route")
        let r = try await auto.synthesize(character: character(speaker: 1), text: "配線確認", in: tmp)
        let expected = try WavFile.duration(of: tmp.appendingPathComponent("tone.wav"))
        XCTAssertEqual(r.duration, expected, accuracy: 0.001)
        let paths = FakeCoeiroinkV2Server.calls.map(\.path)
        XCTAssertEqual(paths, ["/v1/engine_info", "/v1/speakers", "/v1/synthesis"], "\(paths)")
    }

    // 3: エンジン未起動時は従来どおり v1 側の案内文で止まる(案内文が v2 用に変わらない)
    func testEngineUnavailableKeepsV1Guidance() async {
        FakeCoeiroinkV2Server.engineInfoStatus = 404
        FakeCoeiroinkV2Server.versionStatus = 404   // v1 側の生存確認も失敗 = エンジン未起動
        let auto = autoProvider(cacheName: "unavail")
        do {
            _ = try await auto.synthesize(character: character(), text: "x", in: tmp)
            XCTFail("throw されるはず")
        } catch let e as VoiceError {
            let msg = e.errorDescription ?? ""
            XCTAssertTrue(msg.hasPrefix("COEIROINK に接続できません"), msg)
            XCTAssertFalse(msg.contains("COEIROINK v2 に接続できません"), msg)
            XCTAssertTrue(msg.contains("http://127.0.0.1:50032"), msg)
        } catch { XCTFail("VoiceError ではない: \(error)") }
        let paths = FakeCoeiroinkV2Server.calls.map(\.path)
        XCTAssertFalse(paths.contains("/synthesis"), "\(paths)")
        XCTAssertFalse(paths.contains("/v1/synthesis"), "\(paths)")
    }

    // 4: アクセント句つき合成は v1 環境で従来どおり v1 の差し替え合成へ委譲される
    func testAccentDelegatesToV1WhenNotV2() async throws {
        FakeCoeiroinkV2Server.engineInfoStatus = 404
        let auto = autoProvider(cacheName: "accent-v1")
        let phrases = samplePhrases()
        _ = try await auto.synthesizeWithAccent(character: character(), text: "アクセント", accentPhrases: phrases, in: tmp)
        let calls = FakeCoeiroinkV2Server.calls
        XCTAssertEqual(calls.map(\.path), ["/v1/engine_info", "/version", "/audio_query", "/synthesis"], "\(calls.map(\.path))")
        let body = try JSONSerialization.jsonObject(with: try XCTUnwrap(calls.last?.body)) as! [String: Any]
        let sent = try XCTUnwrap(VoicevoxAccent.phrases(fromJSONObject: try XCTUnwrap(body["accent_phrases"])))
        XCTAssertEqual(sent, phrases)
    }

    // 5: アクセント句つき合成は v2 環境では通常の v2 合成に落ちる(v2 にアクセント API が無いため)
    func testAccentFallsBackToNormalSynthesisWhenV2() async throws {
        let auto = autoProvider(cacheName: "accent-v2")
        _ = try await auto.synthesizeWithAccent(character: character(speaker: 1), text: "アクセント", accentPhrases: samplePhrases(), in: tmp)
        let paths = FakeCoeiroinkV2Server.calls.map(\.path)
        XCTAssertEqual(paths, ["/v1/engine_info", "/v1/speakers", "/v1/synthesis"], "\(paths)")
    }
}
