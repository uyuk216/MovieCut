import XCTest
import AVFoundation
@testable import YukkuriCore

/// URLProtocol の差し替え(偽 VOICEVOX サーバ)。
final class FakeVoicevox: URLProtocol {
    struct Call { var method: String; var url: String; var path: String; var query: String?; var body: Data? }
    nonisolated(unsafe) static var calls: [Call] = []
    nonisolated(unsafe) static var status = 200
    static let lock = NSLock()

    static func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [FakeVoicevox.self]
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
            Self.calls.append(Call(method: request.httpMethod ?? "GET", url: u.absoluteString, path: comps.percentEncodedPath, query: comps.percentEncodedQuery, body: body))
        }
        var data = Data()
        switch comps.path {
        case "/speakers": data = Data(#"[{"name":"ずんだもん","styles":[{"id":3,"name":"ノーマル"},{"id":1,"name":"あまあま"}]}]"#.utf8)
        case "/audio_query": data = Data(#"{"accent_phrases":[],"speedScale":9,"pitchScale":9,"intonationScale":9,"volumeScale":9,"outputSamplingRate":24000}"#.utf8)
        case "/synthesis": data = Data("RIFFfake".utf8)
        default: break
        }
        let resp = HTTPURLResponse(url: u, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class VoiceUnitTests: XCTestCase {
    var tmp: URL!
    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("voice-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        FakeVoicevox.calls = []; FakeVoicevox.status = 200
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func testShellQuote() {
        XCTAssertEqual(shellQuote("abc"), "'abc'")
        XCTAssertEqual(shellQuote("it's"), #"'it'\''s'"#)
        XCTAssertEqual(shellQuote(""), "''")
        XCTAssertEqual(shellQuote("$(rm -rf /) `x` \"y\""), #"'$(rm -rf /) `x` "y"'"#)
    }

    func testTemplateReplacement() {
        let cmd = applyCommandTemplate(defaultAquesTalkCommand, text: "こんにちは'", voice: "れいむ", speed: "100", out: "/tmp/a b.wav")
        XCTAssertEqual(cmd, #"/Applications/AquesTalkPlayer.app/Contents/MacOS/AquesTalkPlayer -P 'れいむ' -T 'こんにちは'\''' -W '/tmp/a b.wav'"#)
        XCTAssertEqual(applyCommandTemplate("x {speed} {speed} {voice}", text: "", voice: nil, speed: "80", out: ""), "x '80' '80' ''")
    }

    func testCacheKeyStableAndSensitive() {
        let base: [JSONValue] = [.string("vv"), .string("http://127.0.0.1:50021"), .string("テキスト"), .number(3), .number(1), .number(0), .number(1), .null]
        let k = VoiceCache.key(base)
        XCTAssertEqual(k, VoiceCache.key(base))
        XCTAssertEqual(k.count, 64)
        XCTAssertEqual(k, k.lowercased())
        XCTAssertTrue(k.allSatisfy { $0.isHexDigit })
        for i in base.indices {
            var m = base
            switch base[i] {
            case .string(let s): m[i] = .string(s + "x")
            case .number(let n): m[i] = .number(n + 0.5)
            default: m[i] = .number(1)
            }
            XCTAssertNotEqual(k, VoiceCache.key(m), "index \(i)")
        }
    }

    func testCacheHit() throws {
        let cache = VoiceCache(directory: tmp.appendingPathComponent("v"))
        let key = VoiceCache.key([.string("k")])
        XCTAssertNil(cache.hit(forKey: key))
        let u = try cache.url(forKey: key)
        try Data("x".utf8).write(to: u)
        XCTAssertEqual(cache.hit(forKey: key), u)
        XCTAssertEqual(u.lastPathComponent, key + ".wav")
    }

    func testScriptLineParsing() {
        let chars = Project.new().characters   // 霊夢 魔理沙 ずんだもん
        let sel = chars[1].id
        func p(_ l: String) -> String? { ScriptTimeline.parse(line: l, characters: chars, selectedCharId: sel).map { "\($0.0.name)|\($0.1)" } }
        XCTAssertEqual(p("霊夢: こんにちは"), "霊夢|こんにちは")
        XCTAssertEqual(p("霊夢：こんにちは"), "霊夢|こんにちは")
        XCTAssertEqual(p("  ずんだもん :  なのだ  "), "ずんだもん|なのだ")
        XCTAssertEqual(p("だれか: やあ"), "魔理沙|だれか: やあ")   // 不明な名前 → 選択中キャラ、行全体
        XCTAssertEqual(p("ただのセリフ"), "魔理沙|ただのセリフ")
        XCTAssertEqual(p("霊夢: 時間は3:00だぜ"), "霊夢|時間は3:00だぜ")   // セリフ中のコロンは残す
        XCTAssertEqual(p(": こんにちは"), "魔理沙|: こんにちは")
        XCTAssertEqual(p("霊夢:"), "魔理沙|霊夢:")
        XCTAssertNil(p("   "))
        XCTAssertEqual(ScriptTimeline.parse(line: "x", characters: chars, selectedCharId: nil)?.0.name, "霊夢")  // 選択無し → 先頭
    }

    func testClipDurationMath() {
        XCTAssertEqual(ScriptTimeline.clipDuration(forAudio: 1.5), 1.65, accuracy: 1e-9)
    }

    /// 長さ固定のダミー声で配置(開始・間隔 0.1・レイヤー再利用)を確かめる。
    func testAddLinesLayout() async throws {
        var p = Project.new()
        let before = p.tracks.count
        let tone = ToneVoiceProvider(durations: [1.0, 2.0], frequencies: [220])
        let added = try await ScriptTimeline.add(lines: ["霊夢: あ", "", "魔理沙：い", "なにか", "ずんだもん: う"], to: &p, voice: tone, directory: tmp, selectedCharId: p.characters[1].id)
        XCTAssertEqual(added.count, 4)
        XCTAssertEqual(p.tracks.filter { $0.clips.count == 4 }.count, 1)
        XCTAssertEqual(p.tracks.count, before)   // 空のレイヤーが「全部ボイス」として再利用される
        let starts = added.map(\.start), durs = added.map(\.duration)
        XCTAssertEqual(starts[0], 0, accuracy: 1e-6)
        for i in 1..<added.count { XCTAssertEqual(starts[i], starts[i-1] + durs[i-1] + 0.1, accuracy: 1e-6) }
        XCTAssertEqual(durs[0], 1.15, accuracy: 0.01)
        XCTAssertEqual(added.map { $0.text ?? "" }, ["あ", "い", "なにか", "う"])
        XCTAssertEqual(added.map { clipRef in p.characters.first(where: { c in c.id == clipRef.charId })?.name ?? "" }, ["霊夢", "魔理沙", "魔理沙", "ずんだもん"])
        // 2 回目は同じレイヤーの末尾に続く
        let again = try await ScriptTimeline.add(lines: ["霊夢: え"], to: &p, voice: tone, directory: tmp)
        XCTAssertEqual(again[0].start, starts[3] + durs[3], accuracy: 1e-6)   // renderer.js と同じ: 次の台本は trackEnd(間隔なし)から
    }

    func testRegenerateVoice() async throws {
        let p = Project.new()
        var clip = Clip(); clip.type = .voice; clip.charId = p.characters[0].id; clip.text = "あ"; clip.offset = 0.7; clip.duration = 9; clip.src = "/old.wav"
        let tone = ToneVoiceProvider(durations: [1.25], frequencies: [220])
        try await regenerateVoice(clip: &clip, project: p, provider: tone)
        XCTAssertEqual(clip.offset ?? 0, 0, accuracy: 1e-9)
        XCTAssertEqual(clip.duration, 1.4, accuracy: 0.01)
        XCTAssertNotEqual(clip.src, "/old.wav")
    }

    func testDependencyMessages() async {
        var st = DependencyStatus(voicevoxInstalled: false, voicevoxRunning: false, aquestalkPlayerInstalled: false)
        XCTAssertEqual(st.notice.count, 2)
        XCTAssertTrue(st.notice[0].contains("https://voicevox.hiroshiba.jp/"))
        XCTAssertTrue(st.notice[1].contains("https://www.a-quest.com/products/aquestalkplayer.html"))
        st = DependencyStatus(voicevoxInstalled: false, voicevoxRunning: true, aquestalkPlayerInstalled: true)
        XCTAssertTrue(st.notice.isEmpty)
        let chk = await DependencyStatus.check(project: { var p = Project.new(); p.voicevoxUrl = "http://127.0.0.1:1"; return p }(), voicevoxBinary: "/nonexistent/run", aquestalkPath: "/nonexistent/aq")
        XCTAssertEqual(chk, DependencyStatus(voicevoxInstalled: false, voicevoxRunning: false, aquestalkPlayerInstalled: false))
    }

    func testAquesTalkFallbackSelection() {
        let none = AquesTalkSynthesizer(cache: VoiceCache(directory: tmp), playerPath: "/nonexistent/aq")
        XCTAssertTrue(none.effectiveCommand(defaultAquesTalkCommand).usingFallback)
        XCTAssertEqual(none.effectiveCommand(defaultAquesTalkCommand).command, kyokoFallbackCommand)
        XCTAssertFalse(none.effectiveCommand("echo {out}").usingFallback)   // 利用者が変えたコマンドは尊重
        let have = AquesTalkSynthesizer(cache: VoiceCache(directory: tmp), playerPath: "/bin/ls")
        XCTAssertFalse(have.effectiveCommand(defaultAquesTalkCommand).usingFallback)
    }

    func testAquesTalkFailureReportsStderr() async {
        let aq = AquesTalkSynthesizer(cache: VoiceCache(directory: tmp), playerPath: "/bin/ls")
        do {
            _ = try await aq.synthesize(text: "x", voice: nil, speed: nil, commandTemplate: "echo oops-message 1>&2; exit 3 # {out}")
            XCTFail("失敗するはず")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("コマンド失敗 (3)"))
            XCTAssertTrue(error.localizedDescription.contains("oops-message"))
        }
    }

    func testVoicevoxClientCalls() async throws {
        let client = VoicevoxClient(baseURL: "http://fake.local:50021/", cache: VoiceCache(directory: tmp), session: FakeVoicevox.session())
        let url = try await client.synthesize(text: "ずんだ もん&=?", speaker: 3, speed: 1.2, pitch: 0.1, intonation: 1.5, volume: 0.8)
        let calls = FakeVoicevox.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].method, "POST")
        XCTAssertEqual(calls[0].path, "/audio_query")
        XCTAssertEqual(calls[0].query, "text=%E3%81%9A%E3%82%93%E3%81%A0%20%E3%82%82%E3%82%93%26%3D%3F&speaker=3")
        XCTAssertEqual(calls[1].method, "POST")
        XCTAssertEqual(calls[1].path, "/synthesis")
        XCTAssertEqual(calls[1].query, "speaker=3")
        let body = try JSONSerialization.jsonObject(with: calls[1].body ?? Data()) as! [String: Any]
        XCTAssertEqual(body["speedScale"] as? Double, 1.2)
        XCTAssertEqual(body["pitchScale"] as? Double, 0.1)
        XCTAssertEqual(body["intonationScale"] as? Double, 1.5)
        XCTAssertEqual(body["volumeScale"] as? Double, 0.8)
        XCTAssertEqual(body["outputSamplingRate"] as? Int, 24000)   // audio_query の他のキーは保つ
        XCTAssertEqual(try Data(contentsOf: url), Data("RIFFfake".utf8))
        // 2 回目はキャッシュ(通信なし)
        _ = try await client.synthesize(text: "ずんだ もん&=?", speaker: 3, speed: 1.2, pitch: 0.1, intonation: 1.5, volume: 0.8)
        XCTAssertEqual(FakeVoicevox.calls.count, 2)
    }

    func testVoicevoxDefaultsAndSpeakers() async throws {
        let client = VoicevoxClient(baseURL: "http://fake.local:50021", cache: VoiceCache(directory: tmp), session: FakeVoicevox.session())
        _ = try await client.synthesize(text: "あ", speaker: 1)
        let body = try JSONSerialization.jsonObject(with: FakeVoicevox.calls[1].body ?? Data()) as! [String: Any]
        XCTAssertEqual(body["speedScale"] as? Double, 1)
        XCTAssertEqual(body["pitchScale"] as? Double, 0)
        XCTAssertEqual(body["intonationScale"] as? Double, 1)
        XCTAssertEqual(body["volumeScale"] as? Double, 1)
        let sp = try await client.speakers()
        XCTAssertEqual(sp, [VoicevoxSpeaker(name: "ずんだもん", styles: [VoicevoxStyle(id: 3, name: "ノーマル"), VoicevoxStyle(id: 1, name: "あまあま")])])
        XCTAssertEqual(FakeVoicevox.calls.last?.method, "GET")
    }

    func testVoicevoxHTTPError() async {
        FakeVoicevox.status = 500
        let client = VoicevoxClient(baseURL: "http://fake.local:50021", cache: VoiceCache(directory: tmp), session: FakeVoicevox.session())
        do { _ = try await client.synthesize(text: "あ", speaker: 1); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("audio_query")) }
    }
}

/// 実エンジンを使うテスト(入っていなければ skip)。
final class RealEngineTests: XCTestCase {
    var tmp: URL!
    let engine = VoicevoxEngine()
    var weStarted = false
    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("real-voice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        engine.shutdown()
        try? FileManager.default.removeItem(at: tmp)
    }

    func testAquesTalkReimuMatchesElectronReference() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: AquesTalkSynthesizer.playerPath), "AquesTalkPlayer 未インストール")
        let ref = URL(fileURLWithPath: "/Users/USER/開発/アプリケーション/yukkuri-editor/aq_れいむ.wav")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: ref.path), "参照 WAV なし")
        let aq = AquesTalkSynthesizer(cache: VoiceCache(directory: tmp))
        let out = try await aq.synthesize(text: "ゆっくりしていってね", voice: "れいむ", speed: 100, commandTemplate: defaultAquesTalkCommand)
        let a = try Data(contentsOf: out), b = try Data(contentsOf: ref)
        XCTAssertEqual(a.count, b.count, "サイズ")
        XCTAssertTrue(a == b, "Electron 版の WAV とバイト単位で同一")
        XCTAssertGreaterThan(try RealVoiceProvider.duration(of: out), 0.5)
    }

    func testSayFallbackProducesWav() async throws {
        let aq = AquesTalkSynthesizer(cache: VoiceCache(directory: tmp), playerPath: "/nonexistent/aq")
        let out = try await aq.synthesize(text: "ゆっくりしていってね", voice: "れいむ", speed: 100, commandTemplate: defaultAquesTalkCommand)
        XCTAssertGreaterThan(try RealVoiceProvider.duration(of: out), 0.5)
    }

    func testVoicevoxZundamon() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: VoicevoxEngine.defaultBinary), "VOICEVOX 未インストール")
        let base = "http://127.0.0.1:50021"
        let ok = await engine.ensureRunning(baseURL: base)
        XCTAssertTrue(ok)
        let client = VoicevoxClient(baseURL: base, cache: VoiceCache(directory: tmp))
        let sp = try await client.speakers()
        XCTAssertTrue(sp.contains { $0.styles.contains { $0.id == 3 } })
        let url = try await client.synthesize(text: "ずんだもんなのだ", speaker: 3)
        let dur = try RealVoiceProvider.duration(of: url)
        XCTAssertGreaterThan(dur, 0.5)
        let f = try AVAudioFile(forReading: url)
        let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
        try f.read(into: buf)
        var peak: Float = 0
        for i in 0..<Int(buf.frameLength) { peak = max(peak, abs(buf.floatChannelData![0][i])) }
        XCTAssertGreaterThan(peak, 0.05, "無音ではない")
    }

    func testEngineEnsureRunning() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: VoicevoxEngine.defaultBinary), "VOICEVOX 未インストール")
        let base = "http://127.0.0.1:50021"
        let alreadyUp = await VoicevoxEngine.isAlive(baseURL: base)
        let ok = await engine.ensureRunning(baseURL: base)
        XCTAssertTrue(ok)
        if alreadyUp {
            XCTAssertFalse(engine.startedByUs, "すでに動いているものは止めない")
        } else {
            XCTAssertTrue(engine.startedByUs)
            engine.shutdown()
            try await Task.sleep(nanoseconds: 500_000_000)
            let stillUp = await VoicevoxEngine.isAlive(baseURL: base)
            XCTAssertFalse(stillUp, "自分で起動したものは止まる")
        }
        // 非 localhost / バイナリ無しでは起動しない
        let none = VoicevoxEngine(binaryPath: "/nonexistent/run")
        let r = await none.ensureRunning(baseURL: "http://127.0.0.1:59999")
        XCTAssertFalse(r)
    }

    func testRealVoiceProviderEndToEnd() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: VoicevoxEngine.defaultBinary), "VOICEVOX 未インストール")
        var p = Project.new()
        let provider = RealVoiceProvider(project: p, cache: VoiceCache(directory: tmp), engine: engine)
        try await ScriptTimeline.add(lines: ["霊夢: ゆっくりしていってね", "ずんだもん: ずんだもんなのだ"], to: &p, voice: provider, directory: tmp)
        XCTAssertTrue(provider.enginesUsed.contains("voicevox"))
        let clips = p.allClips.filter { $0.type == .voice }.sorted { $0.start < $1.start }
        XCTAssertEqual(clips.count, 2)
        for c in clips {
            let d = try RealVoiceProvider.duration(of: URL(fileURLWithPath: c.src ?? ""))
            XCTAssertEqual(c.duration, d + 0.15, accuracy: 1e-6)
        }
        XCTAssertEqual(clips[1].start, clips[0].start + clips[0].duration + 0.1, accuracy: 1e-6)
    }
}
