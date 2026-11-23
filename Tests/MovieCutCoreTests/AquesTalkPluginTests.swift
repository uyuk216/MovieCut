import XCTest
@testable import MovieCutCore

/// AquesTalk プラグインの等価性テスト。内蔵 `AquesTalkSynthesizer` / `RealVoiceProvider` の aquestalk 分岐と、
/// プラグイン側の複製が同じ条件で同じ振る舞いをすることを確認する。
/// 実プレイヤーが要る部分は、既存テストの流儀どおり「検証を通るダミー実行ファイル(/bin/ls)で引数を比べる」
/// 「プレイヤー無し = say 代用で実際に合成する」の 2 つで代替する(実プレイヤー必須の確認は RealEngineTests 側)。
final class AquesTalkPluginTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("aqplugin-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        WavFakeVoicevox.calls = []; WavFakeVoicevox.wav = Data()
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func freshCache(_ name: String) -> VoiceCache { VoiceCache(directory: tmp.appendingPathComponent(name)) }

    private func aquesCharacter(speed: Double? = 130) -> Character {
        var c = Character(); c.engine = "aquestalk"; c.voice = "女声1"; c.speed = speed
        return c
    }
    private func voicevoxCharacter() -> Character {
        var c = Character(); c.engine = "voicevox"; c.speaker = 5; c.speed = 1.2; c.pitch = 0.1; c.intonation = 1.1
        return c
    }

    /// say 代用になるプラグイン側シンセサイザ(プレイヤー不在の指定)。
    private func pluginSaySynth(cache: VoiceCache) -> AquesTalkPluginSynthesizer {
        AquesTalkPluginSynthesizer(cache: cache, playerPath: "/nonexistent/aq")
    }
    private func builtinSaySynth(cache: VoiceCache) -> AquesTalkSynthesizer {
        AquesTalkSynthesizer(cache: cache, playerPath: "/nonexistent/aq")
    }

    private func aquesHost(cache: VoiceCache) -> PluginHost {
        let loader = BuiltinPluginLoader([AquesTalkPlugin.manifest.id: {
            LoadedPlugin(manifest: AquesTalkPlugin.manifest, directory: self.tmp,
                         voiceProvider: AquesTalkPluginProvider(synthesizer: self.pluginSaySynth(cache: cache)))
        }])
        let host = PluginHost(loader: loader)
        host.register(manifest: AquesTalkPlugin.manifest, directory: tmp)
        return host
    }

    // 1
    func testManifest() throws {
        XCTAssertTrue(AquesTalkPlugin.manifest.handlesVoiceEngine("aquestalk"))
        XCTAssertTrue(AquesTalkPlugin.manifest.handlesVoiceEngine("AquesTalk"))
        XCTAssertFalse(AquesTalkPlugin.manifest.handlesVoiceEngine("voicevox"))
        let folder = tmp.appendingPathComponent("plugins/AquesTalkPlugin", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try AquesTalkPlugin.manifestJSON().write(to: folder.appendingPathComponent(PluginDiscovery.manifestFileName), atomically: true, encoding: .utf8)
        let result = PluginDiscovery.discover(in: [tmp.appendingPathComponent("plugins")])
        XCTAssertEqual(result.plugins.map(\.manifest), [AquesTalkPlugin.manifest])
    }

    // 2
    func testHostLazyLoad() throws {
        let host = aquesHost(cache: freshCache("c"))
        XCTAssertFalse(host.isLoaded(pluginID: AquesTalkPlugin.manifest.id))
        let p = try host.voiceProvider(forEngine: "aquestalk")
        XCTAssertTrue(host.isLoaded(pluginID: AquesTalkPlugin.manifest.id))
        XCTAssertTrue(p is AquesTalkPluginProvider)
        XCTAssertNil(try host.voiceProviderIfAvailable(forEngine: "unknown-engine"))
    }

    // 3: エンジンへ渡す引数の等価性(プレイヤーあり想定 / say 代用)
    func testInvocationEquivalence() {
        let out = tmp.appendingPathComponent("o.wav")
        // プレイヤーあり(/bin/ls は検証を通るダミー)
        let bP = AquesTalkSynthesizer(cache: freshCache("bp"), playerPath: "/bin/ls")
        let pP = AquesTalkPluginSynthesizer(cache: freshCache("pp"), playerPath: "/bin/ls")
        XCTAssertEqual(bP.executable, pP.executable)
        XCTAssertFalse(bP.usingFallback)
        XCTAssertFalse(pP.usingFallback)
        for voice in ["女声1", "女声2", "れいむ", "まりさ", "中性", nil] as [String?] {
            let a = bP.invocation(text: "ゆっくりしていってね", voice: voice, out: out)
            let b = pP.invocation(text: "ゆっくりしていってね", voice: voice, out: out)
            XCTAssertEqual(a.executable, b.executable)
            XCTAssertEqual(a.arguments, b.arguments, "voice=\(voice ?? "nil")")
        }
        // say 代用(プレイヤー無し)
        let bS = builtinSaySynth(cache: freshCache("bs"))
        let pS = pluginSaySynth(cache: freshCache("ps"))
        XCTAssertTrue(bS.usingFallback)
        XCTAssertTrue(pS.usingFallback)
        let a = bS.invocation(text: "-v", voice: nil, out: out)
        let b = pS.invocation(text: "-v", voice: nil, out: out)
        XCTAssertEqual(a.executable, b.executable)
        XCTAssertEqual(a.arguments, b.arguments)
    }

    // 4: 合成の等価性(say 代用で実際に合成し、キャッシュキーの一致 = 速さの渡し方の一致まで見る)
    func testSynthesizeCacheEquivalence() async throws {
        // 同じキャッシュフォルダを共有すると、キーが一致する側同士は同じファイルに当たる。
        let shared = freshCache("shared")
        let builtin = builtinSaySynth(cache: shared)
        let plugin = pluginSaySynth(cache: shared)
        let text = "ゆっくりしていってね"

        // 速さ 130(%): 内蔵で作ったファイルにプラグインがそのまま当たる(キーが完全一致する証拠)
        let u130 = try await builtin.synthesize(text: text, voice: "女声1", speed: 130)
        let p130 = try await plugin.synthesize(text: text, voice: "女声1", speed: 130)
        XCTAssertEqual(u130, p130)
        XCTAssertGreaterThan(try RealVoiceProvider.duration(of: u130), 0.5)

        // 速さ 100 は別のキャッシュ行になり、そちらも両者で一致する(速さを勝手に変換していないこと)
        let p100 = try await plugin.synthesize(text: text, voice: "女声1", speed: 100)
        XCTAssertNotEqual(p100, u130)
        let u100 = try await builtin.synthesize(text: text, voice: "女声1", speed: 100)
        XCTAssertEqual(u100, p100)

        // 速さ未指定(nil)も両者で一致する
        let uNil = try await builtin.synthesize(text: text, voice: "女声1", speed: nil)
        let pNil = try await plugin.synthesize(text: text, voice: "女声1", speed: nil)
        XCTAssertEqual(uNil, pNil)
    }

    // 5: プロバイダ経路の等価性(RealVoiceProvider の aquestalk 分岐 vs プラグイン)
    func testProviderPathEquivalence() async throws {
        let shared = freshCache("prov")
        let builtin = RealVoiceProvider(project: Project.new(), aquestalk: builtinSaySynth(cache: shared))
        let plugin = AquesTalkPluginProvider(synthesizer: pluginSaySynth(cache: shared))
        let ch = aquesCharacter(speed: 130)

        let a = try await builtin.synthesize(character: ch, text: "ゆっくりしていってね", in: tmp)
        let b = try await plugin.synthesize(character: ch, text: "ゆっくりしていってね", in: tmp)
        XCTAssertEqual(a.url, b.url)
        XCTAssertEqual(a.duration, b.duration, accuracy: 0.001)
        XCTAssertEqual(builtin.enginesUsed, ["say"])
        XCTAssertEqual(plugin.enginesUsed, ["say"])
        XCTAssertTrue(plugin.usingFallback)
    }

    // 5b: 実プレイヤーでの等価性(入っていなければ skip。内蔵の参照テスト testAquesTalkReimuMatchesElectronReference と同じ流儀)
    func testRealPlayerMatchesElectronReference() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: AquesTalkSynthesizer.playerPath), "AquesTalkPlayer 未インストール")
        let ref = try XCTUnwrap(Bundle.module.url(forResource: "aq_reimu", withExtension: "wav", subdirectory: "Fixtures"))
        let synth = AquesTalkPluginSynthesizer(cache: freshCache("real"))
        let out = try await synth.synthesize(text: "ゆっくりしていってね", voice: "女声1（AquesTalk1）", speed: 100)
        let a = try Data(contentsOf: out), b = try Data(contentsOf: ref)
        XCTAssertEqual(a.count, b.count, "サイズ")
        XCTAssertTrue(a == b, "Electron 版の WAV とバイト単位で同一(プラグイン経由)")
    }

    // 6a
    func testRoutingNoPluginUsesFallback() async throws {
        let fb = RecordingVoiceProvider()
        let router = PluginVoiceRoutingProvider(host: PluginHost(loader: BuiltinPluginLoader([:])), fallback: fb)
        _ = try await router.synthesize(character: aquesCharacter(), text: "a", in: tmp)
        _ = try await router.synthesize(character: voicevoxCharacter(), text: "b", in: tmp)
        XCTAssertEqual(fb.engines, ["aquestalk", "voicevox"])
    }

    // 6b: AquesTalk だけ登録 → aquestalk はプラグイン、voicevox は従来どおり fallback
    func testRoutingAquesTalkPluginOnly() async throws {
        let fb = RecordingVoiceProvider()
        let router = PluginVoiceRoutingProvider(host: aquesHost(cache: freshCache("r")), fallback: fb)

        let r = try await router.synthesize(character: aquesCharacter(), text: "ゆっくりしていってね", in: tmp)
        XCTAssertGreaterThan(r.duration, 0.5)
        XCTAssertTrue(fb.engines.isEmpty)

        _ = try await router.synthesize(character: voicevoxCharacter(), text: "b", in: tmp)
        XCTAssertEqual(fb.engines, ["voicevox"])
    }

    // 6c: 両プラグイン登録 → voicevox は VOICEVOX プラグイン、aquestalk は AquesTalk プラグイン
    func testRoutingBothPlugins() async throws {
        let wavURL = tmp.appendingPathComponent("tone.wav")
        try ToneVoiceProvider.writeTone(to: wavURL, duration: 0.3, frequency: 330)
        WavFakeVoicevox.wav = try Data(contentsOf: wavURL)
        let expected = try WavFile.duration(of: wavURL)

        let aqCache = freshCache("both-aq")
        let loader = BuiltinPluginLoader([
            VoicevoxPlugin.manifest.id: {
                let p = VoicevoxPluginProvider(baseURL: "http://fake.local:50021", cache: self.freshCache("both-vv"), session: WavFakeVoicevox.session(), policy: VoiceEndpointPolicy(allowRemote: true, allowedHosts: ["fake.local"]))
                p.engineAvailabilityOverride = { _ in true }
                return LoadedPlugin(manifest: VoicevoxPlugin.manifest, directory: self.tmp, voiceProvider: p)
            },
            AquesTalkPlugin.manifest.id: {
                LoadedPlugin(manifest: AquesTalkPlugin.manifest, directory: self.tmp,
                             voiceProvider: AquesTalkPluginProvider(synthesizer: self.pluginSaySynth(cache: aqCache)))
            }
        ])
        let host = PluginHost(loader: loader)
        host.register(manifest: VoicevoxPlugin.manifest, directory: tmp)
        host.register(manifest: AquesTalkPlugin.manifest, directory: tmp)
        let fb = RecordingVoiceProvider()
        let router = PluginVoiceRoutingProvider(host: host, fallback: fb)

        let rv = try await router.synthesize(character: voicevoxCharacter(), text: "テスト", in: tmp)
        XCTAssertEqual(rv.duration, expected, accuracy: 0.001)

        let ra = try await router.synthesize(character: aquesCharacter(), text: "ゆっくりしていってね", in: tmp)
        XCTAssertGreaterThan(ra.duration, 0.5)
        XCTAssertTrue(fb.engines.isEmpty)
    }

    // 6d
    func testRoutingBrokenPluginFallsBack() async throws {
        struct Boom: Error {}
        let host = PluginHost(loader: ClosurePluginLoader { _, _ in throw Boom() })
        host.register(manifest: AquesTalkPlugin.manifest, directory: tmp)
        let fb = RecordingVoiceProvider()
        let router = PluginVoiceRoutingProvider(host: host, fallback: fb)
        _ = try await router.synthesize(character: aquesCharacter(), text: "a", in: tmp)
        XCTAssertEqual(fb.engines, ["aquestalk"])
    }
}


/// AquesTalk プラグインの合成まわりの回帰(第2部 C09)。
/// 内蔵側は第1部で直っていた「失敗時のキャッシュ汚染」が、プラグイン側では最終パスへ直接生成していた。
/// また `run` の標準エラー読みとタイムアウトは、内蔵・プラグイン両方に同じ欠けがあった。
final class AquesTalkPluginRunTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("aqplugin-run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func makeScript(_ name: String, _ body: String) throws -> URL {
        let url = tmp.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// 失敗した合成の壊れた WAV が、プラグインのキャッシュに残らないこと(内蔵側の回帰と対)。
    func testPluginFailedSynthesisDoesNotPoisonCache() async throws {
        let flag = tmp.appendingPathComponent("failflag")
        let player = try makeScript("player.sh",
            "while [ $# -gt 0 ]; do if [ \"$1\" = \"-W\" ]; then out=\"$2\"; fi; shift; done\n"
            + "if [ -f \"\(flag.path)\" ]; then printf 'PARTIAL' > \"$out\"; exit 1; fi\n"
            + "printf 'FULLWAV' > \"$out\"\nexit 0\n")
        let cache = VoiceCache(directory: tmp.appendingPathComponent("cache"))
        let synth = AquesTalkPluginSynthesizer(cache: cache, playerPath: player.path)
        try Data().write(to: flag)
        do { _ = try await synth.synthesize(text: "テスト", voice: nil, speed: nil); XCTFail("失敗するはず") } catch {}
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: cache.directory.path)) ?? []
        XCTAssertTrue(leftovers.filter { $0.hasSuffix(".wav") }.isEmpty,
                      "失敗した合成の壊れた WAV がキャッシュに残っている: \(leftovers)")
        try FileManager.default.removeItem(at: flag)
        let url = try await synth.synthesize(text: "テスト", voice: nil, speed: nil)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "FULLWAV")
    }

    /// 標準エラーへ大量に出力するコマンドでも、パイプが満杯になって止まらないこと(プラグイン・内蔵の両方)。
    func testRunDrainsLargeStderr() async throws {
        let script = try makeScript("noisy.sh",
            "i=0; while [ $i -lt 6000 ]; do echo 'diagnostic line padding padding padding' >&2; i=$((i+1)); done\n"
            + "printf 'FULLWAV' > \"$1\"\nexit 0\n")
        let out1 = tmp.appendingPathComponent("o1.wav")
        try await AquesTalkPluginSynthesizer.run(executable: script, arguments: [out1.path], expecting: out1, timeout: 20)
        XCTAssertEqual(try String(contentsOf: out1, encoding: .utf8), "FULLWAV")
        let out2 = tmp.appendingPathComponent("o2.wav")
        try await AquesTalkSynthesizer.run(executable: script, arguments: [out2.path], expecting: out2, timeout: 20)
        XCTAssertEqual(try String(contentsOf: out2, encoding: .utf8), "FULLWAV")
    }

    /// 終了要求(SIGTERM)を無視するコマンドでも、強制終了して待ちが戻ること。
    func testRunForceKillsProcessIgnoringSIGTERM() async throws {
        let script = try makeScript("stubborn.sh",
            "trap '' TERM\nprintf 'X' > \"$1\"\nsleep 30\n")
        let out = tmp.appendingPathComponent("o.wav")
        let start = Date()
        do {
            try await AquesTalkPluginSynthesizer.run(executable: script, arguments: [out.path], expecting: out, timeout: 0.5)
            XCTFail("タイムアウトで失敗するはず")
        } catch {}
        XCTAssertLessThan(Date().timeIntervalSince(start), 10, "SIGKILL へ格上げされず待ちが戻らなかった")
    }
}
