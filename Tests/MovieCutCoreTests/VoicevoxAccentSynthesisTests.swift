import XCTest
import Foundation
@testable import MovieCutCore

/// audio_query が実物に近い accent_phrases を返す偽サーバ(既存の偽サーバは触らず、別に用意)。
final class AccentFakeVoicevox: URLProtocol {
    struct Call { var method: String; var path: String; var query: String?; var body: Data? }
    nonisolated(unsafe) static var calls: [Call] = []
    static let lock = NSLock()

    static func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [AccentFakeVoicevox.self]
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
        let comps = URLComponents(url: u, resolvingAgainstBaseURL: false)!
        Self.lock.withLock {
            Self.calls.append(Call(method: request.httpMethod ?? "GET", path: comps.percentEncodedPath, query: comps.percentEncodedQuery, body: body))
        }
        var data = Data()
        switch comps.path {
        case "/audio_query": data = Data(sampleAudioQueryJSON.utf8)
        case "/synthesis": data = Data("RIFFfake".utf8)
        default: break
        }
        let resp = HTTPURLResponse(url: u, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// 内蔵 VoicevoxClient とプラグイン VoicevoxPluginClient の両方で、同じ期待を同じ手順で検証する。
final class VoicevoxAccentSynthesisTests: XCTestCase {
    var tmp: URL!
    static let base = "http://fake.local:50021"
    static let policy = VoiceEndpointPolicy(allowRemote: true, allowedHosts: ["fake.local"])

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vvaccent-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        AccentFakeVoicevox.calls = []
        FakeVoicevox.calls = []; FakeVoicevox.status = 200
        WavFakeVoicevox.calls = []; WavFakeVoicevox.wav = Data()
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func sample() throws -> [VoicevoxAccentPhrase] {
        let q = try JSONSerialization.jsonObject(with: Data(sampleAudioQueryJSON.utf8)) as! [String: Any]
        return try XCTUnwrap(VoicevoxAccent.phrases(fromQuery: q))
    }

    private func builtin(_ name: String) -> VoicevoxClient {
        VoicevoxClient(baseURL: Self.base, cache: VoiceCache(directory: tmp.appendingPathComponent(name)), session: AccentFakeVoicevox.session(), policy: Self.policy)
    }
    private func plugin(_ name: String) -> VoicevoxPluginClient {
        VoicevoxPluginClient(baseURL: Self.base, cache: VoiceCache(directory: tmp.appendingPathComponent(name)), session: AccentFakeVoicevox.session(), policy: Self.policy)
    }

    private func synthBody() throws -> [String: Any] {
        let call = try XCTUnwrap(AccentFakeVoicevox.calls.last)
        XCTAssertEqual(call.path, "/synthesis")
        return try JSONSerialization.jsonObject(with: try XCTUnwrap(call.body)) as! [String: Any]
    }

    // クロージャで両クライアントを同じ形に包む
    typealias Synth = (_ text: String, _ accent: [VoicevoxAccentPhrase]?) async throws -> URL
    typealias Fetch = (_ text: String) async throws -> [VoicevoxAccentPhrase]

    private func variants() -> [(String, Synth, Fetch)] {
        let b = builtin("b"), p = plugin("p")
        return [
            ("builtin", { try await b.synthesize(text: $0, speaker: 3, accentPhrases: $1) }, { try await b.accentPhrases(text: $0, speaker: 3) }),
            ("plugin", { try await p.synthesize(text: $0, speaker: 3, accentPhrases: $1) }, { try await p.accentPhrases(text: $0, speaker: 3) }),
        ]
    }

    func testAccentPhrasesFetch() async throws {
        for (name, _, fetch) in variants() {
            AccentFakeVoicevox.calls = []
            let got = try await fetch("こんにちは")
            XCTAssertEqual(got, try sample(), name)
            XCTAssertEqual(AccentFakeVoicevox.calls.count, 1, name)
            XCTAssertEqual(AccentFakeVoicevox.calls[0].path, "/audio_query", name)
            XCTAssertEqual(AccentFakeVoicevox.calls[0].method, "POST", name)
        }
    }

    func testSynthesisBodyHasReplacedAccentPhrases() async throws {
        var edited = try sample()
        edited[0].accent = 2
        edited[1].moras[0].pitch = 6.5
        for (name, synth, _) in variants() {
            AccentFakeVoicevox.calls = []
            _ = try await synth("こんにちは", edited)
            XCTAssertEqual(AccentFakeVoicevox.calls.map(\.path), ["/audio_query", "/synthesis"], name)
            let body = try synthBody()
            let sent = try XCTUnwrap(VoicevoxAccent.phrases(fromJSONObject: try XCTUnwrap(body["accent_phrases"])), name)
            XCTAssertEqual(sent, edited, name)
            XCTAssertEqual(sent[0].accent, 2, name)
            XCTAssertEqual(body["outputSamplingRate"] as? Int, 24000, name)   // 他のキーは保つ
            XCTAssertEqual(body["speedScale"] as? Double, 1, name)
        }
    }

    func testNilAccentKeepsEngineAccentPhrases() async throws {
        for (name, synth, _) in variants() {
            AccentFakeVoicevox.calls = []
            _ = try await synth("こんにちは", nil)
            let body = try synthBody()
            // audio_query が返した accent_phrases がそのまま(差し替えなし)
            let sent = try XCTUnwrap(VoicevoxAccent.phrases(fromJSONObject: try XCTUnwrap(body["accent_phrases"])), name)
            XCTAssertEqual(sent, try sample(), name)
        }
    }

    func testCacheKeyChangesWithAccentAndNilMatchesLegacy() async throws {
        for (name, synth, _) in variants() {
            AccentFakeVoicevox.calls = []
            let plain = try await synth("こんにちは", nil)
            XCTAssertEqual(AccentFakeVoicevox.calls.count, 2, name)
            // nil は従来のキーと同一: 引数なしの呼び出しはキャッシュに当たる
            let legacyKey = VoiceCache.key([.string("vv"), .string(Self.base), .string("こんにちは"), .number(3), .null, .null, .null, .null, .number(0.03), .number(0.03), .number(0.65)])
            XCTAssertEqual(plain.lastPathComponent, legacyKey + ".wav", name)

            var a = try sample(); a[0].accent = 1
            var b = try sample(); b[0].accent = 2
            let ua = try await synth("こんにちは", a)
            let ub = try await synth("こんにちは", b)
            XCTAssertNotEqual(ua, plain, name)
            XCTAssertNotEqual(ua, ub, name)
            let calls = AccentFakeVoicevox.calls.count
            XCTAssertEqual(calls, 6, name)
            // 同じ編集内容は再通信なしでキャッシュ
            let ua2 = try await synth("こんにちは", a)
            XCTAssertEqual(ua2, ua, name)
            XCTAssertEqual(AccentFakeVoicevox.calls.count, calls, name)
            // 同じ値でも pitch だけ違えば別キー
            var c = a; c[0].moras[0].pitch += 0.1
            let uc = try await synth("こんにちは", c)
            XCTAssertNotEqual(uc, ua, name)
        }
    }

    func testBuiltinAndPluginShareCacheKeys() async throws {
        var edited = try sample(); edited[1].accent = 2
        let u1 = try await builtin("x").synthesize(text: "あ", speaker: 3, accentPhrases: edited)
        let u2 = try await plugin("y").synthesize(text: "あ", speaker: 3, accentPhrases: edited)
        XCTAssertEqual(u1.lastPathComponent, u2.lastPathComponent)
    }

    func testNilAccentSameStepsAsBeforeWithFakeVoicevox() async throws {
        // 既存の偽サーバで、引数なし呼び出しと accentPhrases: nil が同じ通信になる
        func run(_ explicitNil: Bool) async throws -> [String] {
            FakeVoicevox.calls = []
            let c = VoicevoxClient(baseURL: Self.base, cache: VoiceCache(directory: tmp.appendingPathComponent(UUID().uuidString)), session: FakeVoicevox.session(), policy: Self.policy)
            if explicitNil { _ = try await c.synthesize(text: "あ", speaker: 1, speed: 1.2, accentPhrases: nil) }
            else { _ = try await c.synthesize(text: "あ", speaker: 1, speed: 1.2) }
            return FakeVoicevox.calls.map { VoicevoxPluginTests.describe(method: $0.method, path: $0.path, query: $0.query, body: $0.body) }
        }
        let a = try await run(false), b = try await run(true)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 2)
    }

    func testWavFakeVoicevoxPluginSendsAccent() async throws {
        // WavFakeVoicevox(accent_phrases が空の audio_query)でも差し替え内容が /synthesis に載る
        WavFakeVoicevox.wav = Data("RIFFfake".utf8)
        let client = VoicevoxPluginClient(baseURL: Self.base, cache: VoiceCache(directory: tmp.appendingPathComponent("w")), session: WavFakeVoicevox.session(), policy: Self.policy)
        let edited = try sample()
        _ = try await client.synthesize(text: "あ", speaker: 5, accentPhrases: edited)
        let call = try XCTUnwrap(WavFakeVoicevox.calls.last)
        XCTAssertEqual(call.path, "/synthesis")
        let body = try JSONSerialization.jsonObject(with: try XCTUnwrap(call.body)) as! [String: Any]
        XCTAssertEqual(VoicevoxAccent.phrases(fromJSONObject: try XCTUnwrap(body["accent_phrases"])), edited)
    }
}

// MARK: - プロバイダ伝達

final class AccentRecordingProvider: VoicevoxAccentProviding {
    nonisolated(unsafe) var plain: [String] = []
    nonisolated(unsafe) var accented: [(String, [VoicevoxAccentPhrase])] = []
    func synthesize(character: Character, text: String, in directory: URL) async throws -> VoiceResult {
        plain.append(text); return VoiceResult(url: directory.appendingPathComponent("a.wav"), duration: 1)
    }
    func synthesizeWithAccent(character: Character, text: String, accentPhrases: [VoicevoxAccentPhrase], in directory: URL) async throws -> VoiceResult {
        accented.append((text, accentPhrases)); return VoiceResult(url: directory.appendingPathComponent("b.wav"), duration: 2)
    }
}
final class AccentPlainProvider: VoiceProvider {
    nonisolated(unsafe) var texts: [String] = []
    func synthesize(character: Character, text: String, in directory: URL) async throws -> VoiceResult {
        texts.append(text); return VoiceResult(url: directory.appendingPathComponent("p.wav"), duration: 1)
    }
}

final class VoicevoxAccentForwardingTests: XCTestCase {
    var tmp: URL!
    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vvaccent-fwd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        AccentFakeVoicevox.calls = []
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func phrases() throws -> [VoicevoxAccentPhrase] {
        let q = try JSONSerialization.jsonObject(with: Data(sampleAudioQueryJSON.utf8)) as! [String: Any]
        return try XCTUnwrap(VoicevoxAccent.phrases(fromQuery: q))
    }
    private func vvChar() -> Character { var c = Character(); c.engine = "voicevox"; c.speaker = 3; return c }

    func testDictionaryForwardsConvertedTextAndAccent() async throws {
        let inner = AccentRecordingProvider()
        let dict = DictionaryVoiceProvider(inner: inner, entries: [ReadingEntry(word: "世界", reading: "せかい")])
        let r = try await dict.synthesizeWithAccent(character: vvChar(), text: "世界です", accentPhrases: try phrases(), in: tmp)
        XCTAssertEqual(r.duration, 2)
        XCTAssertEqual(inner.accented.count, 1)
        XCTAssertEqual(inner.accented[0].0, "せかいです")
        XCTAssertEqual(inner.accented[0].1, try phrases())
        XCTAssertTrue(inner.plain.isEmpty)
    }

    func testDictionaryEmptyPassesTextThrough() async throws {
        let inner = AccentRecordingProvider()
        let dict = DictionaryVoiceProvider(inner: inner, entries: [])
        _ = try await dict.synthesizeWithAccent(character: vvChar(), text: "世界です", accentPhrases: try phrases(), in: tmp)
        XCTAssertEqual(inner.accented.first?.0, "世界です")
    }

    func testDictionaryFallsBackForNonConformingInner() async throws {
        let inner = AccentPlainProvider()
        let dict = DictionaryVoiceProvider(inner: inner, entries: [ReadingEntry(word: "世界", reading: "せかい")])
        let r = try await dict.synthesizeWithAccent(character: vvChar(), text: "世界です", accentPhrases: try phrases(), in: tmp)
        XCTAssertEqual(r.duration, 1)
        XCTAssertEqual(inner.texts, ["せかいです"])
    }

    func testRoutingForwardsToFallbackWhenConforming() async throws {
        let fb = AccentRecordingProvider()
        let routing = PluginVoiceRoutingProvider(host: PluginHost(loader: BuiltinPluginLoader([:])), fallback: fb)
        _ = try await routing.synthesizeWithAccent(character: vvChar(), text: "あ", accentPhrases: try phrases(), in: tmp)
        XCTAssertEqual(fb.accented.count, 1)
        XCTAssertTrue(fb.plain.isEmpty)
    }

    func testRoutingFallsBackToPlainWhenNonConforming() async throws {
        let fb = AccentPlainProvider()
        let routing = PluginVoiceRoutingProvider(host: PluginHost(loader: BuiltinPluginLoader([:])), fallback: fb)
        _ = try await routing.synthesizeWithAccent(character: vvChar(), text: "あ", accentPhrases: try phrases(), in: tmp)
        XCTAssertEqual(fb.texts, ["あ"])
    }

    func testRoutingForwardsToResolvedPluginProvider() async throws {
        let session = AccentFakeVoicevox.session()
        let cache = VoiceCache(directory: tmp.appendingPathComponent("c"))
        let policy = VoiceEndpointPolicy(allowRemote: true, allowedHosts: ["fake.local"])
        let loader = BuiltinPluginLoader([VoicevoxPlugin.manifest.id: {
            let p = VoicevoxPluginProvider(baseURL: "http://fake.local:50021", cache: cache, session: session, policy: policy)
            p.engineAvailabilityOverride = { _ in true }
            return LoadedPlugin(manifest: VoicevoxPlugin.manifest, directory: self.tmp, voiceProvider: p)
        }])
        let host = PluginHost(loader: loader)
        host.register(manifest: VoicevoxPlugin.manifest, directory: tmp)
        let fb = AccentRecordingProvider()
        let routing = PluginVoiceRoutingProvider(host: host, fallback: fb)
        var edited = try phrases(); edited[0].accent = 1
        // 偽 WAV(RIFFfake)は長さを読めないため、通信内容だけ確認する
        _ = try? await routing.synthesizeWithAccent(character: vvChar(), text: "あ", accentPhrases: edited, in: tmp)
        XCTAssertTrue(fb.accented.isEmpty && fb.plain.isEmpty)
        let body = try JSONSerialization.jsonObject(with: try XCTUnwrap(AccentFakeVoicevox.calls.last?.body)) as! [String: Any]
        XCTAssertEqual(VoicevoxAccent.phrases(fromJSONObject: try XCTUnwrap(body["accent_phrases"])), edited)
    }

    func testRealVoiceProviderAccentOnlyForVoicevoxCharacter() async throws {
        var project = Project.new()
        project.voicevoxUrl = "http://fake.local:50021"
        let policy = VoiceEndpointPolicy(allowRemote: true, allowedHosts: ["fake.local"])
        let real = RealVoiceProvider(project: project, cache: VoiceCache(directory: tmp.appendingPathComponent("r")), session: AccentFakeVoicevox.session(), policy: policy)
        // アクセント非対応の AquesTalk キャラは VOICEVOX へ一切通信しない(通常合成に落ちる)
        var aq = Character(); aq.engine = "aquestalk"
        _ = try? await real.synthesizeWithAccent(character: aq, text: "あ", accentPhrases: try phrases(), in: tmp)
        XCTAssertTrue(AccentFakeVoicevox.calls.isEmpty)
    }
}
