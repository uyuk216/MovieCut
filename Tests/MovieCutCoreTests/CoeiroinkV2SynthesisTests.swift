import XCTest
@testable import MovieCutCore

/// COEIROINK v2 のモックサーバ(URLProtocol)。
/// v2 の確定形式に忠実に実装する: GET /v1/speakers・GET /v1/engine_info・POST /v1/synthesis(WAV を返す)。
/// 自動判定プロバイダの v1 委譲を検証するため、v1 互換の GET /version・POST /audio_query・POST /synthesis も返す。
/// /v1/synthesis のリクエスト JSON が確定形式(必須スケール類)を満たさない場合は 422 を返し、
/// クライアント側の形式崩れをテストで検出できるようにする。
final class FakeCoeiroinkV2Server: URLProtocol {
    struct Call { var method: String; var path: String; var body: Data? }
    nonisolated(unsafe) static var calls: [Call] = []
    nonisolated(unsafe) static var wav = Data()
    nonisolated(unsafe) static var engineInfoStatus = 200
    nonisolated(unsafe) static var versionStatus = 200
    nonisolated(unsafe) static var synthesisStatus = 200
    nonisolated(unsafe) static var duplicateStyle = false
    static let lock = NSLock()

    static func reset() {
        lock.withLock { calls = []; engineInfoStatus = 200; versionStatus = 200; synthesisStatus = 200; duplicateStyle = false }
    }
    static func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [FakeCoeiroinkV2Server.self]
        return URLSession(configuration: c)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody
        if body == nil, let s = request.httpBodyStream {
            s.open(); var d = Data(); var buf = [UInt8](repeating: 0, count: 4096)
            while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; d.append(buf, count: n) }
            s.close(); body = d
        }
        let u = request.url!
        Self.lock.withLock { Self.calls.append(Call(method: request.httpMethod ?? "GET", path: u.path, body: body)) }
        var data = Data()
        var status = 200
        switch u.path {
        case "/v1/speakers":
            if Self.duplicateStyle {
                // スタイル ID 2 が 2 話者に重なるケース(解決の曖昧さ検証用)
                data = Data(#"""
                [
                  {"speakerName": "つくよみちゃん", "speakerUuid": "uuid-tsukuyomi", "styles": [{"styleName": "れいせい", "styleId": 0}]},
                  {"speakerName": "テスト話者", "speakerUuid": "uuid-test", "styles": [{"styleName": "ノーマル", "styleId": 2}]},
                  {"speakerName": "別話者", "speakerUuid": "uuid-other", "styles": [{"styleName": "ノーマル", "styleId": 2}]}
                ]
                """#.utf8)
            } else {
                data = Data(#"""
                [
                  {"speakerName": "つくよみちゃん", "speakerUuid": "uuid-tsukuyomi", "version": "2.0.0", "styles": [{"styleName": "れいせい", "styleId": 0}, {"styleName": "おしとやか", "styleId": 1}]},
                  {"speakerName": "テスト話者", "speakerUuid": "uuid-test", "version": "2.0.0", "styles": [{"styleName": "ノーマル", "styleId": 2}]}
                ]
                """#.utf8)
            }
        case "/v1/engine_info":
            status = Self.engineInfoStatus
            if status == 200 { data = Data(#"{"version": "2.13.0", "device": "cpu"}"#.utf8) }
        case "/v1/synthesis":
            status = Self.synthesisStatus
            if status == 200 {
                // 確定形式の必須キーが欠けていたら 422(実エンジンのバリデーション相当)
                let obj = body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
                let required = ["speakerUuid", "styleId", "text", "speedScale", "volumeScale", "pitchScale", "intonationScale", "prePhonemeLength", "postPhonemeLength", "outputSamplingRate"]
                if obj == nil || !required.allSatisfy({ obj?[$0] != nil }) { status = 422 } else { data = Self.wav }
            }
        case "/version":
            status = Self.versionStatus
            if status == 200 { data = Data(#""1.0.0""#.utf8) }
        case "/audio_query":
            data = Data(#"{"accent_phrases":[],"speedScale":9,"outputSamplingRate":24000}"#.utf8)
        case "/synthesis":
            data = Self.wav
        default:
            status = 404
        }
        let resp = HTTPURLResponse(url: u, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// R3-1: COEIROINK v2 合成。実エンジンは未導入のため、v2 の確定形式に忠実なモックサーバで
/// リクエスト形式・話者解決・プロバイダ経路・自動判定・エラー処理を検証する。
/// 実エンジン確認の手順は docs/追加TTS-COEIROINK-SHAREVOX.md。
final class CoeiroinkV2SynthesisTests: XCTestCase {
    var tmp: URL!
    static let policy = VoiceEndpointPolicy(allowRemote: true, allowedHosts: ["fake.local"])
    static let fakeBase = "http://fake.local:50032"

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("coeiro-v2-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        FakeCoeiroinkV2Server.reset()
        let wavURL = tmp.appendingPathComponent("tone.wav")
        try ToneVoiceProvider.writeTone(to: wavURL, duration: 0.4, frequency: 440)
        FakeCoeiroinkV2Server.wav = try Data(contentsOf: wavURL)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func freshCache(_ name: String) -> VoiceCache { VoiceCache(directory: tmp.appendingPathComponent(name)) }
    private func v2Client(cacheName: String = "c") -> CoeiroinkV2Client {
        CoeiroinkV2Client(baseURL: Self.fakeBase, session: FakeCoeiroinkV2Server.session(), policy: Self.policy, cache: freshCache(cacheName))
    }
    private func synthesisBody(_ call: FakeCoeiroinkV2Server.Call) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: try XCTUnwrap(call.body)) as! [String: Any]
    }
    private func v2Character(speaker: Int? = 1) -> Character {
        var c = Character(); c.engine = "coeiroink"; c.speaker = speaker; c.speed = 1.2; c.pitch = 0.1; c.intonation = 1.1
        return c
    }

    // 1: 合成リクエスト形式(UUID 指定)。確定形式のキー集合と値、メソッド・パスを検証し、2 回目はキャッシュで完結する
    func testSynthesizeRequestFormatWithUUID() async throws {
        let client = v2Client()
        let url = try await client.synthesize(text: "こんにちは", speakerUuid: "uuid-tsukuyomi", styleId: 1, speed: 1.2, pitch: 0.1, intonation: 1.1)
        XCTAssertEqual(try Data(contentsOf: url), FakeCoeiroinkV2Server.wav)
        XCTAssertEqual(FakeCoeiroinkV2Server.calls.count, 1)
        let call = FakeCoeiroinkV2Server.calls[0]
        XCTAssertEqual(call.method, "POST")
        XCTAssertEqual(call.path, "/v1/synthesis")
        let body = try synthesisBody(call)
        XCTAssertEqual(Set(body.keys), ["speakerUuid", "styleId", "text", "speedScale", "volumeScale", "pitchScale", "intonationScale", "prePhonemeLength", "postPhonemeLength", "outputSamplingRate"])
        XCTAssertEqual(body["speakerUuid"] as? String, "uuid-tsukuyomi")
        XCTAssertEqual((body["styleId"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual(body["text"] as? String, "こんにちは")
        XCTAssertEqual(body["speedScale"] as? Double, 1.2)
        XCTAssertEqual(body["pitchScale"] as? Double, 0.1)
        XCTAssertEqual(body["intonationScale"] as? Double, 1.1)
        XCTAssertEqual(body["volumeScale"] as? Double, 1)              // 未指定は 1
        XCTAssertEqual(body["prePhonemeLength"] as? Double, 0.1)       // v2 の既定(v1 の 0.03 ではない)
        XCTAssertEqual(body["postPhonemeLength"] as? Double, 0.1)
        XCTAssertEqual((body["outputSamplingRate"] as? NSNumber)?.intValue, 24000)

        // 同じ条件の 2 回目はキャッシュヒットでサーバへ行かない
        let again = try await client.synthesize(text: "こんにちは", speakerUuid: "uuid-tsukuyomi", styleId: 1, speed: 1.2, pitch: 0.1, intonation: 1.1)
        XCTAssertEqual(again, url)
        XCTAssertEqual(FakeCoeiroinkV2Server.calls.count, 1)
    }

    // 2: 既定値(パラメータ未指定)と明示パラメータ(音量・間・サンプルレート)
    func testSynthesizeDefaultsAndExplicitParameters() async throws {
        let client = v2Client()
        _ = try await client.synthesize(text: "既定", speakerUuid: "uuid-test", styleId: 2)
        var body = try synthesisBody(FakeCoeiroinkV2Server.calls.last!)
        XCTAssertEqual(body["speedScale"] as? Double, 1)
        XCTAssertEqual(body["pitchScale"] as? Double, 0)
        XCTAssertEqual(body["intonationScale"] as? Double, 1)
        XCTAssertEqual(body["volumeScale"] as? Double, 1)

        let client2 = v2Client(cacheName: "c2")
        _ = try await client2.synthesize(text: "明示", speakerUuid: "uuid-test", styleId: 2, volume: 0.5, prePhonemeLength: 0.2, postPhonemeLength: 0.3, outputSamplingRate: 44100)
        body = try synthesisBody(FakeCoeiroinkV2Server.calls.last!)
        XCTAssertEqual(body["volumeScale"] as? Double, 0.5)
        XCTAssertEqual(body["prePhonemeLength"] as? Double, 0.2)
        XCTAssertEqual(body["postPhonemeLength"] as? Double, 0.3)
        XCTAssertEqual((body["outputSamplingRate"] as? NSNumber)?.intValue, 44100)
    }

    // 3: 話者一覧 → スタイル ID 解決 → 合成の一連(リクエスト順序と解決後の UUID)
    func testSpeakersResolveAndSynthesizeByStyleId() async throws {
        let client = v2Client()
        let voice = try await client.resolveVoice(styleId: 2)
        XCTAssertEqual(voice.speakerUuid, "uuid-test")
        XCTAssertEqual(voice.speakerName, "テスト話者")
        XCTAssertEqual(voice.style, VoicevoxStyle(id: 2, name: "ノーマル"))

        FakeCoeiroinkV2Server.reset()
        _ = try await client.synthesize(text: "解決して合成", styleId: 2)
        XCTAssertEqual(FakeCoeiroinkV2Server.calls.map(\.path), ["/v1/speakers", "/v1/synthesis"])
        let body = try synthesisBody(FakeCoeiroinkV2Server.calls.last!)
        XCTAssertEqual(body["speakerUuid"] as? String, "uuid-test")
        XCTAssertEqual((body["styleId"] as? NSNumber)?.intValue, 2)
    }

    // 4: スタイル ID が無い場合は合成に進まず、日本語の理由で止まる
    func testStyleIdNotFound() async {
        let client = v2Client()
        do {
            _ = try await client.synthesize(text: "x", styleId: 999)
            XCTFail("throw されるはず")
        } catch let e as VoiceError {
            XCTAssertTrue((e.errorDescription ?? "").contains("スタイル ID 999"), e.errorDescription ?? "")
        } catch { XCTFail("VoiceError ではない: \(error)") }
        XCTAssertEqual(FakeCoeiroinkV2Server.calls.map(\.path), ["/v1/speakers"])
    }

    // 5: スタイル ID が複数話者に一致する場合は推測で選ばず止まる
    func testStyleIdAmbiguous() async {
        FakeCoeiroinkV2Server.duplicateStyle = true
        let client = v2Client()
        do {
            _ = try await client.resolveVoice(styleId: 2)
            XCTFail("throw されるはず")
        } catch let e as VoiceError {
            let msg = e.errorDescription ?? ""
            XCTAssertTrue(msg.contains("複数の話者"), msg)
            XCTAssertTrue(msg.contains("uuid-other"), msg)
        } catch { XCTFail("VoiceError ではない: \(error)") }
    }

    // 6: エンジン情報と生存確認(GET /v1/engine_info)
    func testEngineInfoAndAlive() async throws {
        let client = v2Client()
        let info = try await client.engineInfo()
        XCTAssertEqual(info, CoeiroinkEngineInfo(version: "2.13.0", device: "cpu"))
        let alive = await client.isAlive()
        XCTAssertTrue(alive)
        FakeCoeiroinkV2Server.engineInfoStatus = 404
        let dead = await client.isAlive()
        XCTAssertFalse(dead)
    }

    // 7: 合成の HTTP エラーは VoiceError.http で伝わる
    func testSynthesizeHTTPError() async {
        FakeCoeiroinkV2Server.synthesisStatus = 500
        let client = v2Client()
        do {
            _ = try await client.synthesize(text: "x", speakerUuid: "uuid-test", styleId: 2)
            XCTFail("throw されるはず")
        } catch let e as VoiceError {
            guard case .http(let what, let code) = e else { return XCTFail("http ではない: \(e)") }
            XCTAssertEqual(what, "v1/synthesis")
            XCTAssertEqual(code, 500)
        } catch { XCTFail("VoiceError ではない: \(error)") }
    }

    // 8: プロバイダ経路(実プローブ → 解決 → 合成。長さが一致し、パラメータが v2 形式で渡る)
    func testProviderPath() async throws {
        let provider = CoeiroinkPlugin.makeV2Provider(baseURL: Self.fakeBase, cache: freshCache("prov"), session: FakeCoeiroinkV2Server.session(), policy: Self.policy)
        let r = try await provider.synthesize(character: v2Character(speaker: 1), text: "テスト", in: tmp)
        let expected = try WavFile.duration(of: tmp.appendingPathComponent("tone.wav"))
        XCTAssertEqual(r.duration, expected, accuracy: 0.001)
        XCTAssertEqual(FakeCoeiroinkV2Server.calls.map(\.path), ["/v1/engine_info", "/v1/speakers", "/v1/synthesis"])
        let body = try synthesisBody(FakeCoeiroinkV2Server.calls.last!)
        XCTAssertEqual(body["speakerUuid"] as? String, "uuid-tsukuyomi")
        XCTAssertEqual(body["speedScale"] as? Double, 1.2)
        XCTAssertEqual(body["pitchScale"] as? Double, 0.1)
        XCTAssertEqual(body["intonationScale"] as? Double, 1.1)
    }

    // 9: v2 エンジン未起動なら日本語の案内で止まり、合成には進まない
    func testProviderEngineUnavailable() async {
        FakeCoeiroinkV2Server.engineInfoStatus = 404
        let provider = CoeiroinkPlugin.makeV2Provider(baseURL: Self.fakeBase, cache: freshCache("unavail"), session: FakeCoeiroinkV2Server.session(), policy: Self.policy)
        do {
            _ = try await provider.synthesize(character: v2Character(), text: "x", in: tmp)
            XCTFail("throw されるはず")
        } catch let e as VoiceError {
            XCTAssertTrue((e.errorDescription ?? "").hasPrefix("COEIROINK v2 に接続できません"), e.errorDescription ?? "")
        } catch { XCTFail("VoiceError ではない: \(error)") }
        XCTAssertFalse(FakeCoeiroinkV2Server.calls.contains { $0.path == "/v1/synthesis" })
    }

    // 10: 話者未設定のキャラは既定スタイル ID 0 で合成する
    func testProviderDefaultStyleId() async throws {
        let provider = CoeiroinkPlugin.makeV2Provider(baseURL: Self.fakeBase, cache: freshCache("def"), session: FakeCoeiroinkV2Server.session(), policy: Self.policy)
        provider.engineAvailabilityOverride = { _ in true }
        _ = try await provider.synthesize(character: v2Character(speaker: nil), text: "既定話者", in: tmp)
        let body = try synthesisBody(FakeCoeiroinkV2Server.calls.last!)
        XCTAssertEqual((body["styleId"] as? NSNumber)?.intValue, CoeiroinkV2Provider.defaultStyleId)
        XCTAssertEqual(body["speakerUuid"] as? String, "uuid-tsukuyomi")
    }

    // 11: キャッシュは v1 経路と分ける(同じ接続先・同じ文・同じ数値 ID でも混ざらない)
    func testCacheSeparatedFromV1() async throws {
        let shared = freshCache("shared")
        let session = FakeCoeiroinkV2Server.session()
        let v1 = CoeiroinkPlugin.makeClient(baseURL: Self.fakeBase, cache: shared, session: session, policy: Self.policy)
        let v2shared = CoeiroinkV2Client(baseURL: Self.fakeBase, session: session, policy: Self.policy, cache: shared)
        let u1 = try await v1.synthesize(text: "同じ文", speaker: 2)
        let u2 = try await v2shared.synthesize(text: "同じ文", speakerUuid: "uuid-test", styleId: 2)
        XCTAssertNotEqual(u1.lastPathComponent, u2.lastPathComponent)
        XCTAssertTrue(FakeCoeiroinkV2Server.calls.contains { $0.path == "/audio_query" })
        XCTAssertTrue(FakeCoeiroinkV2Server.calls.contains { $0.path == "/v1/synthesis" })
    }

    // 12: 自動判定(v2 が応答すれば v2 経路。v1 の audio_query は呼ばない)
    func testAutoProviderRoutesToV2() async throws {
        let provider = CoeiroinkPlugin.makeAutoProvider(baseURL: Self.fakeBase, cache: freshCache("auto2"), session: FakeCoeiroinkV2Server.session(), policy: Self.policy)
        _ = try await provider.synthesize(character: v2Character(speaker: 2), text: "自動判定", in: tmp)
        let paths = FakeCoeiroinkV2Server.calls.map(\.path)
        XCTAssertTrue(paths.contains("/v1/synthesis"), "\(paths)")
        XCTAssertFalse(paths.contains("/audio_query"), "\(paths)")
    }

    // 13: 自動判定(v2 が応答しなければ従来の v1 経路へ委譲し、合成手順は従来どおり)
    func testAutoProviderFallsBackToV1() async throws {
        FakeCoeiroinkV2Server.engineInfoStatus = 404
        let provider = CoeiroinkPlugin.makeAutoProvider(baseURL: Self.fakeBase, cache: freshCache("auto1"), session: FakeCoeiroinkV2Server.session(), policy: Self.policy)
        let r = try await provider.synthesize(character: v2Character(speaker: 2), text: "自動判定", in: tmp)
        let expected = try WavFile.duration(of: tmp.appendingPathComponent("tone.wav"))
        XCTAssertEqual(r.duration, expected, accuracy: 0.001)
        let paths = FakeCoeiroinkV2Server.calls.map(\.path)
        XCTAssertEqual(paths.first, "/v1/engine_info", "\(paths)")   // 判定の参照が先行するだけ
        XCTAssertTrue(paths.contains("/audio_query"), "\(paths)")
        XCTAssertTrue(paths.contains("/synthesis"), "\(paths)")
        XCTAssertFalse(paths.contains("/v1/synthesis"), "\(paths)")
    }
}
