import XCTest
@testable import MovieCutCore

/// COEIROINK v2 の /v1/speakers だけを返す偽サーバ(camelCase と snake_case を混ぜる)。
final class FakeCoeiroinkV2: URLProtocol {
    nonisolated(unsafe) static var calls: [String] = []
    static let lock = NSLock()

    static func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [FakeCoeiroinkV2.self]
        return URLSession(configuration: c)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let u = request.url!
        Self.lock.withLock { Self.calls.append(u.path) }
        var data = Data()
        if u.path == "/v1/speakers" {
            data = Data(#"""
            [
              {"speakerName": "つくよみちゃん", "speakerUuid": "uuid-tsukuyomi", "styles": [{"styleName": "れいせい", "styleId": 0}, {"styleName": "おしとやか", "styleId": 1}]},
              {"speaker_name": "テスト話者", "speaker_uuid": "uuid-test", "styles": [{"style_name": "ノーマル", "style_id": 2}]}
            ]
            """#.utf8)
        }
        let resp = HTTPURLResponse(url: u, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// W3-09: COEIROINK / SHAREVOX プラグイン(VOICEVOX 系共通クライアント)。
/// 実エンジンは未導入のため、モックサーバ(URLProtocol)での疎通・パラメータ変換・
/// プラグイン未登録時の従来一致までを検証する。実エンジン確認の手順は docs/追加TTS-COEIROINK-SHAREVOX.md。
final class CoeiroinkSharevoxPluginTests: XCTestCase {
    var tmp: URL!
    static let policy = VoiceEndpointPolicy(allowRemote: true, allowedHosts: ["fake.local"])
    static let fakeBase = "http://fake.local:50021"

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("familytts-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        FakeVoicevox.calls = []; FakeVoicevox.status = 200
        WavFakeVoicevox.calls = []; WavFakeVoicevox.wav = Data()
        AccentFakeVoicevox.calls = []
        FakeCoeiroinkV2.calls = []
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func freshCache(_ name: String) -> VoiceCache { VoiceCache(directory: tmp.appendingPathComponent(name)) }

    private func familyCharacter(engine: String) -> Character {
        var c = Character(); c.engine = engine; c.speaker = 5; c.speed = 1.2; c.pitch = 0.1; c.intonation = 1.1
        return c
    }

    private func normalized(_ calls: [FakeVoicevox.Call]) -> [String] {
        calls.map { VoicevoxPluginTests.describe(method: $0.method, path: $0.path, query: $0.query, body: $0.body) }
    }
    private func normalized(_ calls: [WavFakeVoicevox.Call]) -> [String] {
        calls.map { VoicevoxPluginTests.describe(method: $0.method, path: $0.path, query: $0.query, body: $0.body) }
    }

    private func providerHost(session: URLSession, available: Bool = true) -> PluginHost {
        let make: (VoicevoxFamilyEngineSpec) -> LoadedPlugin = { spec in
            let p = VoicevoxFamilyPluginProvider(spec: spec, baseURL: Self.fakeBase, cache: self.freshCache("host-\(spec.engineID)"), session: session, policy: Self.policy)
            p.engineAvailabilityOverride = { _ in available }
            let manifest = spec.engineID == CoeiroinkPlugin.engineID ? CoeiroinkPlugin.manifest : SharevoxPlugin.manifest
            return LoadedPlugin(manifest: manifest, directory: self.tmp, voiceProvider: p)
        }
        let loader = BuiltinPluginLoader([
            CoeiroinkPlugin.manifest.id: { make(CoeiroinkPlugin.spec) },
            SharevoxPlugin.manifest.id: { make(SharevoxPlugin.spec) },
        ])
        let host = PluginHost(loader: loader)
        host.register(manifest: CoeiroinkPlugin.manifest, directory: tmp)
        host.register(manifest: SharevoxPlugin.manifest, directory: tmp)
        return host
    }

    // 1: マニフェストと探索
    func testManifests() throws {
        XCTAssertTrue(CoeiroinkPlugin.manifest.handlesVoiceEngine("coeiroink"))
        XCTAssertFalse(CoeiroinkPlugin.manifest.handlesVoiceEngine("sharevox"))
        XCTAssertFalse(CoeiroinkPlugin.manifest.handlesVoiceEngine("voicevox"))
        XCTAssertTrue(SharevoxPlugin.manifest.handlesVoiceEngine("sharevox"))
        XCTAssertFalse(SharevoxPlugin.manifest.handlesVoiceEngine("coeiroink"))
        XCTAssertFalse(SharevoxPlugin.manifest.handlesVoiceEngine("aquestalk"))

        for (manifest, json) in [(CoeiroinkPlugin.manifest, try CoeiroinkPlugin.manifestJSON()), (SharevoxPlugin.manifest, try SharevoxPlugin.manifestJSON())] {
            let folder = tmp.appendingPathComponent("plugins/\(manifest.name)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try json.write(to: folder.appendingPathComponent(PluginDiscovery.manifestFileName), atomically: true, encoding: .utf8)
        }
        let result = PluginDiscovery.discover(in: [tmp.appendingPathComponent("plugins")])
        XCTAssertEqual(result.plugins.map(\.manifest).sorted { $0.id < $1.id }, [CoeiroinkPlugin.manifest, SharevoxPlugin.manifest].sorted { $0.id < $1.id })
    }

    // 2: 既定の接続先と仕様の対応(実仕様: COEIROINK 50032 / SHAREVOX 50025)
    func testDefaultEndpointsAndSpecMapping() {
        XCTAssertEqual(CoeiroinkPlugin.defaultBaseURL, "http://127.0.0.1:50032")
        XCTAssertEqual(SharevoxPlugin.defaultBaseURL, "http://127.0.0.1:50025")
        XCTAssertEqual(CoeiroinkPlugin.makeClient().baseURL, CoeiroinkPlugin.defaultBaseURL)
        XCTAssertEqual(SharevoxPlugin.makeClient().baseURL, SharevoxPlugin.defaultBaseURL)
        XCTAssertEqual(VoicevoxFamily.spec(forEngine: "coeiroink"), CoeiroinkPlugin.spec)
        XCTAssertEqual(VoicevoxFamily.spec(forEngine: "sharevox"), SharevoxPlugin.spec)
        XCTAssertNil(VoicevoxFamily.spec(forEngine: "voicevox"))
        XCTAssertNil(VoicevoxFamily.spec(forEngine: "aquestalk"))
        XCTAssertTrue(VoicevoxFamily.isVoicevoxStyleEngine("voicevox"))
        XCTAssertTrue(VoicevoxFamily.isVoicevoxStyleEngine("coeiroink"))
        XCTAssertTrue(VoicevoxFamily.isVoicevoxStyleEngine("sharevox"))
        XCTAssertFalse(VoicevoxFamily.isVoicevoxStyleEngine("aquestalk"))
        // 末尾スラッシュは VOICEVOX プラグインと同じく取り除く
        XCTAssertEqual(CoeiroinkPlugin.makeClient(baseURL: "http://127.0.0.1:50032/").baseURL, "http://127.0.0.1:50032")
    }

    // 3: 話者一覧(両エンジンとも VOICEVOX プラグイン・内蔵と同一の手順と結果)
    func testSpeakersForBothEngines() async throws {
        let session = FakeVoicevox.session()
        for (i, spec) in [CoeiroinkPlugin.spec, SharevoxPlugin.spec].enumerated() {
            let client = VoicevoxFamilyPluginClient(spec: spec, baseURL: Self.fakeBase, cache: freshCache("sp\(i)"), session: session, policy: Self.policy)
            FakeVoicevox.calls = []
            let got = try await client.speakers()
            XCTAssertEqual(FakeVoicevox.calls.count, 1, spec.engineID)
            XCTAssertEqual(FakeVoicevox.calls[0].method, "GET", spec.engineID)
            XCTAssertEqual(FakeVoicevox.calls[0].path, "/speakers", spec.engineID)
            XCTAssertEqual(got, [VoicevoxSpeaker(name: "キャラ2", styles: [VoicevoxStyle(id: 3, name: "ノーマル"), VoicevoxStyle(id: 1, name: "あまあま")])], spec.engineID)
        }
        // 内蔵クライアントとも一致する
        let builtin = VoicevoxClient(baseURL: Self.fakeBase, cache: freshCache("spb"), session: session, policy: Self.policy)
        let want = try await builtin.speakers()
        let plugin = VoicevoxFamilyPluginClient(spec: SharevoxPlugin.spec, baseURL: Self.fakeBase, cache: freshCache("spp"), session: session, policy: Self.policy)
        let pluginSpeakers = try await plugin.speakers()
        XCTAssertEqual(pluginSpeakers, want)
    }

    // 4: 合成リクエストが VOICEVOX プラグインと完全一致する(接続先・テキスト・パラメータが同じ条件)
    func testSynthesizeRequestEquivalenceWithVoicevoxPlugin() async throws {
        let session = FakeVoicevox.session()
        let reference = VoicevoxPluginClient(baseURL: Self.fakeBase, cache: freshCache("ref"), session: session, policy: Self.policy)
        FakeVoicevox.calls = []
        _ = try await reference.synthesize(text: "こんにちは & テスト", speaker: 5, speed: 1.2, pitch: 0.1, intonation: 1.1, volume: 0.8)
        let want = normalized(FakeVoicevox.calls)
        XCTAssertEqual(want.count, 2)

        for (i, spec) in [CoeiroinkPlugin.spec, SharevoxPlugin.spec].enumerated() {
            let client = VoicevoxFamilyPluginClient(spec: spec, baseURL: Self.fakeBase, cache: freshCache("eq\(i)"), session: session, policy: Self.policy)
            FakeVoicevox.calls = []
            _ = try await client.synthesize(text: "こんにちは & テスト", speaker: 5, speed: 1.2, pitch: 0.1, intonation: 1.1, volume: 0.8)
            XCTAssertEqual(normalized(FakeVoicevox.calls), want, spec.engineID)
        }
    }

    // 5: キャッシュキーはエンジンごとに分ける(同じ接続先・同じ文でも混ざらない)
    func testCacheKeysAreSeparatedPerEngine() async throws {
        let session = FakeVoicevox.session()
        let a = VoicevoxFamilyPluginClient(spec: CoeiroinkPlugin.spec, baseURL: Self.fakeBase, cache: freshCache("sep-a"), session: session, policy: Self.policy)
        let b = VoicevoxFamilyPluginClient(spec: SharevoxPlugin.spec, baseURL: Self.fakeBase, cache: freshCache("sep-b"), session: session, policy: Self.policy)
        FakeVoicevox.calls = []
        let ua = try await a.synthesize(text: "同じ文", speaker: 5)
        let ub = try await b.synthesize(text: "同じ文", speaker: 5)
        XCTAssertNotEqual(ua.lastPathComponent, ub.lastPathComponent)
        XCTAssertEqual(FakeVoicevox.calls.count, 4)   // 両方ともサーバへ行った(片方のキャッシュで代用されていない)
        // 同じエンジンの 2 回目はキャッシュヒットでサーバへ行かない
        _ = try await a.synthesize(text: "同じ文", speaker: 5)
        XCTAssertEqual(FakeVoicevox.calls.count, 4)
    }

    // 6: パラメータ変換(VOICEVOX プラグインと同一のキー・既定値)
    func testParameterConversion() async throws {
        let session = FakeVoicevox.session()
        let client = CoeiroinkPlugin.makeClient(baseURL: Self.fakeBase, cache: freshCache("param"), session: session, policy: Self.policy)
        _ = try await client.synthesize(text: "変換", speaker: 5, speed: 1.2, pitch: 0.1, intonation: 1.1)
        var body = try JSONSerialization.jsonObject(with: try XCTUnwrap(FakeVoicevox.calls.last?.body)) as! [String: Any]
        XCTAssertEqual(body["speedScale"] as? Double, 1.2)
        XCTAssertEqual(body["pitchScale"] as? Double, 0.1)
        XCTAssertEqual(body["intonationScale"] as? Double, 1.1)
        XCTAssertEqual(body["volumeScale"] as? Double, 1)              // 未指定は 1
        XCTAssertEqual(body["prePhonemeLength"] as? Double, 0.03)      // VOICEVOX と同じ既定
        XCTAssertEqual(body["postPhonemeLength"] as? Double, 0.03)
        XCTAssertEqual(body["pauseLengthScale"] as? Double, 0.65)

        let client2 = SharevoxPlugin.makeClient(baseURL: Self.fakeBase, cache: freshCache("param2"), session: session, policy: Self.policy)
        _ = try await client2.synthesize(text: "変換2", speaker: 2, volume: 0.5, prePhonemeLength: 0.1, postPhonemeLength: 0.2, pauseLengthScale: 1.0)
        body = try JSONSerialization.jsonObject(with: try XCTUnwrap(FakeVoicevox.calls.last?.body)) as! [String: Any]
        XCTAssertEqual(body["speedScale"] as? Double, 1)               // 未指定は 1
        XCTAssertEqual(body["pitchScale"] as? Double, 0)
        XCTAssertEqual(body["intonationScale"] as? Double, 1)
        XCTAssertEqual(body["volumeScale"] as? Double, 0.5)
        XCTAssertEqual(body["prePhonemeLength"] as? Double, 0.1)
        XCTAssertEqual(body["postPhonemeLength"] as? Double, 0.2)
        XCTAssertEqual(body["pauseLengthScale"] as? Double, 1.0)
    }

    // 7: プロバイダ経路(両エンジン。実 WAV を返し、長さが一致し、リクエストは VOICEVOX プラグインと同一)
    func testProviderPathForBothEngines() async throws {
        let wavURL = tmp.appendingPathComponent("tone.wav")
        try ToneVoiceProvider.writeTone(to: wavURL, duration: 0.4, frequency: 440)
        WavFakeVoicevox.wav = try Data(contentsOf: wavURL)
        let expected = try WavFile.duration(of: wavURL)
        let session = WavFakeVoicevox.session()

        for (i, spec) in [CoeiroinkPlugin.spec, SharevoxPlugin.spec].enumerated() {
            let provider = VoicevoxFamilyPluginProvider(spec: spec, baseURL: Self.fakeBase, cache: freshCache("prov\(i)"), session: session, policy: Self.policy)
            provider.engineAvailabilityOverride = { _ in true }
            let ch = familyCharacter(engine: spec.engineID)
            WavFakeVoicevox.calls = []
            let r = try await provider.synthesize(character: ch, text: "テスト", in: tmp)
            XCTAssertEqual(r.duration, expected, accuracy: 0.001, spec.engineID)
            let got = normalized(WavFakeVoicevox.calls)

            let reference = VoicevoxPluginClient(baseURL: Self.fakeBase, cache: freshCache("prov-ref\(i)"), session: session, policy: Self.policy)
            WavFakeVoicevox.calls = []
            _ = try await reference.synthesize(text: "テスト", speaker: ch.speaker ?? 3, speed: ch.speed, pitch: ch.pitch, intonation: ch.intonation, prePhonemeLength: ch.prePhonemeLength, postPhonemeLength: ch.postPhonemeLength, pauseLengthScale: ch.pauseLengthScale)
            XCTAssertEqual(got.count, 2, spec.engineID)
            XCTAssertEqual(got, normalized(WavFakeVoicevox.calls), spec.engineID)
        }
    }

    // 8: エンジン未起動なら日本語の案内で止まり、合成には進まない
    func testProviderEngineUnavailable() async {
        for spec in [CoeiroinkPlugin.spec, SharevoxPlugin.spec] {
            let provider = VoicevoxFamilyPluginProvider(spec: spec, baseURL: Self.fakeBase, cache: freshCache("unavail-\(spec.engineID)"), session: WavFakeVoicevox.session(), policy: Self.policy)
            provider.engineAvailabilityOverride = { _ in false }
            do {
                _ = try await provider.synthesize(character: familyCharacter(engine: spec.engineID), text: "x", in: tmp)
                XCTFail("throw されるはず")
            } catch let e as VoiceError {
                XCTAssertTrue((e.errorDescription ?? "").hasPrefix("\(spec.displayName) に接続できません"), spec.engineID)
            } catch { XCTFail("VoiceError ではない: \(error)") }
        }
        XCTAssertTrue(WavFakeVoicevox.calls.isEmpty)
    }

    // 9: 生存確認(GET /version)
    func testAvailabilityCheck() async {
        let session = FakeVoicevox.session()
        FakeVoicevox.status = 200
        let alive = await VoicevoxFamilyAvailability.isAlive(baseURL: Self.fakeBase, session: session, policy: Self.policy)
        XCTAssertTrue(alive)
        XCTAssertEqual(FakeVoicevox.calls.last?.path, "/version")
        FakeVoicevox.status = 404
        let dead = await VoicevoxFamilyAvailability.isAlive(baseURL: Self.fakeBase, session: session, policy: Self.policy)
        XCTAssertFalse(dead)
        FakeVoicevox.status = 200
    }

    // 10: アクセント句の取得と差し替え(VOICEVOX プラグインと同じ到達範囲)
    func testAccentPhrasesAndSynthesis() async throws {
        let session = AccentFakeVoicevox.session()
        let q = try JSONSerialization.jsonObject(with: Data(sampleAudioQueryJSON.utf8)) as! [String: Any]
        let sample = try XCTUnwrap(VoicevoxAccent.phrases(fromQuery: q))

        for (i, spec) in [CoeiroinkPlugin.spec, SharevoxPlugin.spec].enumerated() {
            let client = VoicevoxFamilyPluginClient(spec: spec, baseURL: Self.fakeBase, cache: freshCache("acc\(i)"), session: session, policy: Self.policy)
            AccentFakeVoicevox.calls = []
            let got = try await client.accentPhrases(text: "こんにちは", speaker: 3)
            XCTAssertEqual(got, sample, spec.engineID)
            XCTAssertEqual(AccentFakeVoicevox.calls.map(\.path), ["/audio_query"], spec.engineID)

            var edited = sample
            edited[0].accent = 2
            AccentFakeVoicevox.calls = []
            _ = try await client.synthesize(text: "こんにちは", speaker: 3, accentPhrases: edited)
            XCTAssertEqual(AccentFakeVoicevox.calls.map(\.path), ["/audio_query", "/synthesis"], spec.engineID)
            let body = try JSONSerialization.jsonObject(with: try XCTUnwrap(AccentFakeVoicevox.calls.last?.body)) as! [String: Any]
            let sent = try XCTUnwrap(VoicevoxAccent.phrases(fromJSONObject: try XCTUnwrap(body["accent_phrases"])), spec.engineID)
            XCTAssertEqual(sent, edited, spec.engineID)

            // アクセント未指定ならエンジンが返した句をそのまま送る
            AccentFakeVoicevox.calls = []
            _ = try await client.synthesize(text: "こんにちは", speaker: 3)
            let body2 = try JSONSerialization.jsonObject(with: try XCTUnwrap(AccentFakeVoicevox.calls.last?.body)) as! [String: Any]
            let kept = try XCTUnwrap(VoicevoxAccent.phrases(fromJSONObject: try XCTUnwrap(body2["accent_phrases"])), spec.engineID)
            XCTAssertEqual(kept, sample, spec.engineID)
        }
    }

    // 11: COEIROINK v2 の話者一覧(/v1/speakers)の読み取り
    func testCoeiroinkV2SpeakersParsing() async throws {
        let client = CoeiroinkV2Client(baseURL: Self.fakeBase, session: FakeCoeiroinkV2.session(), policy: Self.policy)
        let speakers = try await client.speakers()
        XCTAssertEqual(FakeCoeiroinkV2.calls, ["/v1/speakers"])
        XCTAssertEqual(speakers.count, 2)
        XCTAssertEqual(speakers[0].name, "つくよみちゃん")
        XCTAssertEqual(speakers[0].uuid, "uuid-tsukuyomi")
        XCTAssertEqual(speakers[0].styles, [VoicevoxStyle(id: 0, name: "れいせい"), VoicevoxStyle(id: 1, name: "おしとやか")])
        XCTAssertEqual(speakers[1].name, "テスト話者")
        XCTAssertEqual(speakers[1].uuid, "uuid-test")
        XCTAssertEqual(speakers[1].styles, [VoicevoxStyle(id: 2, name: "ノーマル")])
    }

    // 12: ルーティング(プラグイン登録時は新エンジンがプラグインへ、他は従来の fallback へ)
    func testRoutingWithPlugins() async throws {
        let wavURL = tmp.appendingPathComponent("tone.wav")
        try ToneVoiceProvider.writeTone(to: wavURL, duration: 0.3, frequency: 330)
        WavFakeVoicevox.wav = try Data(contentsOf: wavURL)
        let expected = try WavFile.duration(of: wavURL)
        let fb = RecordingVoiceProvider()
        let host = providerHost(session: WavFakeVoicevox.session())
        let router = PluginVoiceRoutingProvider(host: host, fallback: fb)

        for engine in ["coeiroink", "sharevox"] {
            let r = try await router.synthesize(character: familyCharacter(engine: engine), text: "テスト", in: tmp)
            XCTAssertEqual(r.duration, expected, accuracy: 0.001, engine)
        }
        XCTAssertTrue(fb.engines.isEmpty)

        // VOICEVOX / AquesTalk はこのホストには登録していないので従来どおり fallback
        var vv = Character(); vv.engine = "voicevox"
        var aq = Character(); aq.engine = "aquestalk"
        _ = try await router.synthesize(character: vv, text: "a", in: tmp)
        _ = try await router.synthesize(character: aq, text: "b", in: tmp)
        XCTAssertEqual(fb.engines, ["voicevox", "aquestalk"])
    }

    // 13: プラグイン未登録では従来と完全一致(新エンジンも fallback = 内蔵経路へ)
    func testRoutingNoPluginUsesFallback() async throws {
        let fb = RecordingVoiceProvider()
        let router = PluginVoiceRoutingProvider(host: PluginHost(loader: BuiltinPluginLoader([:])), fallback: fb)
        _ = try await router.synthesize(character: familyCharacter(engine: "coeiroink"), text: "a", in: tmp)
        _ = try await router.synthesize(character: familyCharacter(engine: "sharevox"), text: "b", in: tmp)
        XCTAssertEqual(fb.engines, ["coeiroink", "sharevox"])
    }

    // 14: 壊れたプラグインは fallback に落ちる(VOICEVOX プラグインと同じ方針)
    func testRoutingBrokenPluginFallsBack() async throws {
        struct Boom: Error {}
        let host = PluginHost(loader: ClosurePluginLoader { _, _ in throw Boom() })
        host.register(manifest: CoeiroinkPlugin.manifest, directory: tmp)
        host.register(manifest: SharevoxPlugin.manifest, directory: tmp)
        let fb = RecordingVoiceProvider()
        let router = PluginVoiceRoutingProvider(host: host, fallback: fb)
        _ = try await router.synthesize(character: familyCharacter(engine: "coeiroink"), text: "a", in: tmp)
        _ = try await router.synthesize(character: familyCharacter(engine: "sharevox"), text: "b", in: tmp)
        XCTAssertEqual(fb.engines, ["coeiroink", "sharevox"])
    }

    // 15: 遅延読み込み(登録だけでは本体を作らない)
    func testHostLazyLoad() throws {
        let host = providerHost(session: FakeVoicevox.session())
        XCTAssertFalse(host.isLoaded(pluginID: CoeiroinkPlugin.manifest.id))
        XCTAssertFalse(host.isLoaded(pluginID: SharevoxPlugin.manifest.id))
        let p = try host.voiceProvider(forEngine: "coeiroink")
        XCTAssertTrue(host.isLoaded(pluginID: CoeiroinkPlugin.manifest.id))
        XCTAssertFalse(host.isLoaded(pluginID: SharevoxPlugin.manifest.id))
        XCTAssertTrue(p is VoicevoxFamilyPluginProvider)
        XCTAssertEqual((p as? VoicevoxFamilyPluginProvider)?.spec, CoeiroinkPlugin.spec)
    }

    // 16: エンジン切替と「声を選んだか」(VOICEVOX と同じ単位・判定になる)
    func testSwitchEngineAndVoiceChosen() {
        var c = Character(); c.engine = "aquestalk"; c.speed = 130; c.speaker = nil; c.pitch = nil; c.intonation = nil
        CharacterEditing.switchEngine(&c, to: "coeiroink")
        XCTAssertEqual(c.engine, "coeiroink")
        XCTAssertEqual(c.speed, 1)          // AquesTalk の % 表記は倍率に直す
        XCTAssertEqual(c.pitch, 0)
        XCTAssertEqual(c.intonation, 1)
        XCTAssertEqual(c.speaker, 3)
        XCTAssertTrue(c.hasVoiceChosen)

        var d = Character(); d.engine = "aquestalk"; d.speed = 130
        CharacterEditing.switchEngine(&d, to: "sharevox")
        XCTAssertEqual(d.speed, 1)
        XCTAssertEqual(d.speaker, 3)

        // VOICEVOX 系の範囲内の速さは保持する
        var e = Character(); e.engine = "voicevox"; e.speed = 1.4; e.speaker = 7
        CharacterEditing.switchEngine(&e, to: "coeiroink")
        XCTAssertEqual(e.speed, 1.4)
        XCTAssertEqual(e.speaker, 7)

        // 新エンジンから AquesTalk へ戻すと % 表記に戻る(従来の往復と同じ)
        CharacterEditing.switchEngine(&e, to: "aquestalk")
        XCTAssertEqual(e.speed, 100)

        // 話者未選択の判定と行サブタイトル
        var f = Character(); f.engine = "sharevox"; f.speaker = nil
        XCTAssertFalse(f.hasVoiceChosen)
        f.speaker = 5
        XCTAssertTrue(f.hasVoiceChosen)
        XCTAssertEqual(CharacterRowSubtitle.text(for: f, speakerName: nil), "SHAREVOX 話者 5")
        var g = Character(); g.engine = "coeiroink"; g.speaker = 0
        XCTAssertEqual(CharacterRowSubtitle.text(for: g, speakerName: nil), "COEIROINK 話者 0")
    }

    // 17: おすすめ音声設定(プリセット)でも新エンジンを受け付ける
    func testVoicePresetFamilyEngines() throws {
        let json = #"{"schemaVersion":1,"presets":[{"id":"c1","name":"コエイロ設定","engine":"coeiroink","speaker":5,"speed":1.2},{"id":"s1","name":"シェア設定","engine":"sharevox","speaker":2,"speed":0.9}]}"#
        let catalog = try VoicePresetCatalog.decode(Data(json.utf8))
        XCTAssertEqual(catalog.presets.map(\.engine), ["coeiroink", "sharevox"])
        var ch = Character(); ch.engine = "voicevox"
        let applied = VoicePresetCatalog.applying(catalog.presets[0], to: ch)
        XCTAssertEqual(applied.engine, "coeiroink")
        XCTAssertEqual(applied.speaker, 5)
        XCTAssertEqual(applied.speed, 1.2)
    }

    // 18: 読み辞書は合成直前に効く(プロバイダを包む従来の仕組みが新エンジンでもそのまま使える)
    func testReadingDictionaryAppliesThroughProvider() async throws {
        let wavURL = tmp.appendingPathComponent("tone.wav")
        try ToneVoiceProvider.writeTone(to: wavURL, duration: 0.3, frequency: 330)
        WavFakeVoicevox.wav = try Data(contentsOf: wavURL)
        let provider = SharevoxPlugin.makeProvider(baseURL: Self.fakeBase, cache: freshCache("dict"), session: WavFakeVoicevox.session(), policy: Self.policy)
        provider.engineAvailabilityOverride = { _ in true }
        let entries = [ReadingEntry(word: "相棒", reading: "あいぼう")]
        let wrapped = DictionaryVoiceProvider(inner: provider, entries: entries)
        WavFakeVoicevox.calls = []
        _ = try await wrapped.synthesize(character: familyCharacter(engine: "sharevox"), text: "相棒です", in: tmp)
        let query = try XCTUnwrap(WavFakeVoicevox.calls.first?.query)
        XCTAssertTrue(query.contains("text="), query)
        // 辞書適用後の文が audio_query に渡っている(元の漢字表記は渡らない)
        XCTAssertFalse(query.contains("%E7%9B%B8%E6%A3%92"))   // 「相棒」の % エンコード
        XCTAssertEqual(WavFakeVoicevox.calls.count, 2)
    }
}
