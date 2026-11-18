import XCTest
@testable import MovieCutCore

/// 実 WAV を /synthesis の応答として返す偽 VOICEVOX。
final class WavFakeVoicevox: URLProtocol {
    struct Call { var method: String; var path: String; var query: String?; var body: Data? }
    nonisolated(unsafe) static var calls: [Call] = []
    nonisolated(unsafe) static var wav = Data()
    static let lock = NSLock()

    static func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [WavFakeVoicevox.self]
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
        case "/audio_query": data = Data(#"{"accent_phrases":[],"speedScale":9,"outputSamplingRate":24000}"#.utf8)
        case "/synthesis": data = Self.wav
        default: break
        }
        let resp = HTTPURLResponse(url: u, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// 呼び出しを記録する fallback。
final class RecordingVoiceProvider: VoiceProvider {
    private(set) var engines: [String] = []
    func synthesize(character: Character, text: String, in directory: URL) async throws -> VoiceResult {
        engines.append(character.engine)
        return VoiceResult(url: directory.appendingPathComponent("fallback.wav"), duration: 0.5)
    }
}

final class VoicevoxPluginTests: XCTestCase {
    var tmp: URL!
    static let base = "http://fake.local:50021"
    static let policy = VoiceEndpointPolicy(allowRemote: true, allowedHosts: ["fake.local"])

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vvplugin-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        FakeVoicevox.calls = []; FakeVoicevox.status = 200
        WavFakeVoicevox.calls = []; WavFakeVoicevox.wav = Data()
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func freshCache(_ name: String) -> VoiceCache { VoiceCache(directory: tmp.appendingPathComponent(name)) }

    private func voicevoxCharacter() -> Character {
        var c = Character(); c.engine = "voicevox"; c.speaker = 5; c.speed = 1.2; c.pitch = 0.1; c.intonation = 1.1
        return c
    }
    private func aquesCharacter() -> Character { var c = Character(); c.engine = "aquestalk"; return c }

    private func normalized(_ calls: [FakeVoicevox.Call]) -> [String] {
        calls.map { Self.describe(method: $0.method, path: $0.path, query: $0.query, body: $0.body) }
    }
    private func normalized(_ calls: [WavFakeVoicevox.Call]) -> [String] {
        calls.map { Self.describe(method: $0.method, path: $0.path, query: $0.query, body: $0.body) }
    }
    /// method / path / query と、body を辞書化した内容(キー順非依存)。
    static func describe(method: String, path: String, query: String?, body: Data?) -> String {
        var b = ""
        if let body, let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            b = obj.keys.sorted().map { "\($0)=\(obj[$0]!)" }.joined(separator: ",")
        } else if let body { b = "raw:\(body.count)" }
        return "\(method) \(path) ?\(query ?? "") {\(b)}"
    }

    private func registeredProviderHost(session: URLSession, cache: VoiceCache, available: Bool = true) -> PluginHost {
        let loader = BuiltinPluginLoader([VoicevoxPlugin.manifest.id: {
            let p = VoicevoxPluginProvider(baseURL: Self.base, cache: cache, session: session, policy: Self.policy)
            p.engineAvailabilityOverride = { _ in available }
            return LoadedPlugin(manifest: VoicevoxPlugin.manifest, directory: self.tmp, voiceProvider: p)
        }])
        let host = PluginHost(loader: loader)
        host.register(manifest: VoicevoxPlugin.manifest, directory: tmp)
        return host
    }

    // 1
    func testManifest() throws {
        XCTAssertTrue(VoicevoxPlugin.manifest.handlesVoiceEngine("voicevox"))
        XCTAssertFalse(VoicevoxPlugin.manifest.handlesVoiceEngine("aquestalk"))
        let folder = tmp.appendingPathComponent("plugins/VoicevoxPlugin", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try VoicevoxPlugin.manifestJSON().write(to: folder.appendingPathComponent(PluginDiscovery.manifestFileName), atomically: true, encoding: .utf8)
        let result = PluginDiscovery.discover(in: [tmp.appendingPathComponent("plugins")])
        XCTAssertEqual(result.plugins.map(\.manifest), [VoicevoxPlugin.manifest])
    }

    // 2
    func testHostLazyLoad() throws {
        let host = registeredProviderHost(session: FakeVoicevox.session(), cache: freshCache("c"))
        XCTAssertFalse(host.isLoaded(pluginID: VoicevoxPlugin.manifest.id))
        let p = try host.voiceProvider(forEngine: "voicevox")
        XCTAssertTrue(host.isLoaded(pluginID: VoicevoxPlugin.manifest.id))
        XCTAssertTrue(p is VoicevoxPluginProvider)
        XCTAssertNil(try host.voiceProviderIfAvailable(forEngine: "unknown-engine"))
    }

    // 3
    func testClientEquivalence() async throws {
        let session = FakeVoicevox.session()
        let builtin = VoicevoxClient(baseURL: Self.base, cache: freshCache("a"), session: session, policy: Self.policy)
        let plugin = VoicevoxPluginClient(baseURL: Self.base, cache: freshCache("b"), session: session, policy: Self.policy)

        FakeVoicevox.calls = []
        _ = try await builtin.synthesize(text: "こんにちは & テスト", speaker: 5, speed: 1.2, pitch: 0.1, intonation: 1.1)
        let a = normalized(FakeVoicevox.calls)
        FakeVoicevox.calls = []
        _ = try await plugin.synthesize(text: "こんにちは & テスト", speaker: 5, speed: 1.2, pitch: 0.1, intonation: 1.1)
        let b = normalized(FakeVoicevox.calls)
        XCTAssertEqual(a.count, 2)
        XCTAssertEqual(a, b)

        FakeVoicevox.calls = []
        let sa = try await builtin.speakers()
        let ra = normalized(FakeVoicevox.calls)
        FakeVoicevox.calls = []
        let sb = try await plugin.speakers()
        let rb = normalized(FakeVoicevox.calls)
        XCTAssertEqual(ra, rb)
        XCTAssertEqual(ra.count, 1)
        XCTAssertEqual(sa, sb)
        XCTAssertFalse(sa.isEmpty)
    }

    // 4
    func testProviderPath() async throws {
        let wavURL = tmp.appendingPathComponent("tone.wav")
        try ToneVoiceProvider.writeTone(to: wavURL, duration: 0.4, frequency: 440)
        WavFakeVoicevox.wav = try Data(contentsOf: wavURL)
        let expected = try WavFile.duration(of: wavURL)
        let session = WavFakeVoicevox.session()
        let ch = voicevoxCharacter()

        let provider = VoicevoxPluginProvider(baseURL: Self.base, cache: freshCache("p"), session: session, policy: Self.policy)
        provider.engineAvailabilityOverride = { _ in true }
        WavFakeVoicevox.calls = []
        let r = try await provider.synthesize(character: ch, text: "テスト", in: tmp)
        let got = normalized(WavFakeVoicevox.calls)
        XCTAssertEqual(r.duration, expected, accuracy: 0.001)

        let builtin = VoicevoxClient(baseURL: Self.base, cache: freshCache("q"), session: session, policy: Self.policy)
        WavFakeVoicevox.calls = []
        _ = try await builtin.synthesize(text: "テスト", speaker: ch.speaker ?? 3, speed: ch.speed, pitch: ch.pitch, intonation: ch.intonation, prePhonemeLength: ch.prePhonemeLength, postPhonemeLength: ch.postPhonemeLength, pauseLengthScale: ch.pauseLengthScale)
        let want = normalized(WavFakeVoicevox.calls)
        XCTAssertEqual(got.count, 2)
        XCTAssertEqual(got, want)
    }

    // 5
    func testProviderEngineUnavailable() async {
        let provider = VoicevoxPluginProvider(baseURL: Self.base, cache: freshCache("u"), session: WavFakeVoicevox.session(), policy: Self.policy)
        provider.engineAvailabilityOverride = { _ in false }
        do {
            _ = try await provider.synthesize(character: voicevoxCharacter(), text: "x", in: tmp)
            XCTFail("throw されるはず")
        } catch let e as VoiceError {
            XCTAssertTrue((e.errorDescription ?? "").hasPrefix("VOICEVOX に接続できません"))
        } catch { XCTFail("VoiceError ではない: \(error)") }
        XCTAssertTrue(WavFakeVoicevox.calls.isEmpty)
    }

    // 6a
    func testRoutingNoPluginUsesFallback() async throws {
        let fb = RecordingVoiceProvider()
        let router = PluginVoiceRoutingProvider(host: PluginHost(loader: BuiltinPluginLoader([:])), fallback: fb)
        _ = try await router.synthesize(character: voicevoxCharacter(), text: "a", in: tmp)
        _ = try await router.synthesize(character: aquesCharacter(), text: "b", in: tmp)
        XCTAssertEqual(fb.engines, ["voicevox", "aquestalk"])
    }

    // 6b
    func testRoutingWithPlugin() async throws {
        let wavURL = tmp.appendingPathComponent("tone.wav")
        try ToneVoiceProvider.writeTone(to: wavURL, duration: 0.3, frequency: 330)
        WavFakeVoicevox.wav = try Data(contentsOf: wavURL)
        let expected = try WavFile.duration(of: wavURL)
        let fb = RecordingVoiceProvider()
        let host = registeredProviderHost(session: WavFakeVoicevox.session(), cache: freshCache("r"))
        let router = PluginVoiceRoutingProvider(host: host, fallback: fb)

        let r = try await router.synthesize(character: voicevoxCharacter(), text: "テスト", in: tmp)
        XCTAssertEqual(r.duration, expected, accuracy: 0.001)
        XCTAssertTrue(fb.engines.isEmpty)
        XCTAssertEqual(WavFakeVoicevox.calls.count, 2)

        _ = try await router.synthesize(character: aquesCharacter(), text: "b", in: tmp)
        XCTAssertEqual(fb.engines, ["aquestalk"])
    }

    // 6c
    func testRoutingBrokenPluginFallsBack() async throws {
        struct Boom: Error {}
        let host = PluginHost(loader: ClosurePluginLoader { _, _ in throw Boom() })
        host.register(manifest: VoicevoxPlugin.manifest, directory: tmp)
        let fb = RecordingVoiceProvider()
        let router = PluginVoiceRoutingProvider(host: host, fallback: fb)
        _ = try await router.synthesize(character: voicevoxCharacter(), text: "a", in: tmp)
        XCTAssertEqual(fb.engines, ["voicevox"])
    }
}
