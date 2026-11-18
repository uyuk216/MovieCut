import XCTest
@testable import MovieCutCore

/// プラグイン基盤(マニフェスト探索 / 遅延読み込み / ライセンス検証スタブ / 音声フック)のテスト。
final class PluginFoundationTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("mc-plugin-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
    }

    private func writePluginFolder(name: String, manifestJSON: String) throws -> URL {
        let folder = tempRoot.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try manifestJSON.write(to: folder.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        return folder
    }

    // MARK: - マニフェスト

    func testManifestRoundTripAndCompatibility() throws {
        let manifest = SampleTonePlugin.manifest
        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(PluginManifest.self, from: data)
        XCTAssertEqual(decoded, manifest)
        XCTAssertTrue(decoded.provides(.voice))
        XCTAssertFalse(decoded.provides(.effect))
        XCTAssertTrue(decoded.handlesVoiceEngine("sample-tone"))
        XCTAssertTrue(decoded.handlesVoiceEngine(" SAMPLE-TONE "))
        XCTAssertFalse(decoded.handlesVoiceEngine("voicevox"))
        XCTAssertTrue(decoded.isCompatible(withAppVersion: "1.0.0"))
        XCTAssertTrue(decoded.isCompatible(withAppVersion: "2.3.1"))
        XCTAssertFalse(decoded.isCompatible(withAppVersion: "0.9.9"))
        XCTAssertEqual(PluginManifest.compareVersion("1.10.0", "1.9.0"), .orderedDescending)
        XCTAssertEqual(PluginManifest.compareVersion("1.0", "1.0.0"), .orderedSame)
    }

    func testManifestDecodesMinimalJSON() throws {
        // 任意項目を省いた JSON でも読める(voiceEngineIDs / requiresLicense は既定値)。
        let json = #"{"id":"a.b.c","name":"最小","version":"0.1.0","hooks":["effect"],"entryPoint":"E"}"#
        let decoded = try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.voiceEngineIDs, [])
        XCTAssertFalse(decoded.requiresLicense)
        XCTAssertNil(decoded.minimumAppVersion)
    }

    // MARK: - 探索と登録

    func testDiscoveryRegistersManifestsOnly() throws {
        try SampleTonePlugin.install(into: tempRoot)
        // manifest.json の無いフォルダと、壊れた JSON は失敗として記録されるだけで全体は止まらない。
        let empty = tempRoot.appendingPathComponent("NoManifest", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try writePluginFolder(name: "Broken", manifestJSON: "{ not json")

        let result = PluginDiscovery.discover(in: [tempRoot])
        XCTAssertEqual(result.plugins.map(\.manifest.id), [SampleTonePlugin.pluginID])
        XCTAssertEqual(result.plugins.first?.manifest.entryPoint, SampleTonePlugin.entryPoint)
        XCTAssertEqual(result.failures.count, 2)

        // 登録してもローダは呼ばれない(マニフェストのみ)。
        let loader = SampleTonePluginLoader()
        let host = PluginHost(loader: loader)
        host.register(result)
        XCTAssertEqual(host.registeredManifests.map(\.id), [SampleTonePlugin.pluginID])
        XCTAssertEqual(loader.loadCount, 0)
        XCTAssertFalse(host.isLoaded(pluginID: SampleTonePlugin.pluginID))
        XCTAssertTrue(host.loadedPluginIDs.isEmpty)
    }

    func testDiscoveryRejectsDuplicateIDs() throws {
        let json = try SampleTonePlugin.manifestJSON()
        try writePluginFolder(name: "DupA", manifestJSON: json)
        try writePluginFolder(name: "DupB", manifestJSON: json)
        let result = PluginDiscovery.discover(in: [tempRoot])
        XCTAssertEqual(result.plugins.count, 1)
        XCTAssertTrue(result.failures.contains { $0.reason.contains("重複") })
    }

    // MARK: - 遅延読み込み

    func testUnusedPluginIsNeverInstantiatedAndUsedPluginLoadsOnce() throws {
        try SampleTonePlugin.install(into: tempRoot)
        let loader = SampleTonePluginLoader()
        // ライセンス不要版として登録する(遅延読み込みだけを見るため)。
        var manifest = SampleTonePlugin.manifest
        manifest.requiresLicense = false
        let host = PluginHost(loader: loader)
        host.register(manifest: manifest, directory: tempRoot)

        XCTAssertEqual(loader.loadCount, 0, "登録だけでは実体化しない")
        XCTAssertFalse(host.isLoaded(pluginID: manifest.id))

        let first = try host.loadIfNeeded(pluginID: manifest.id)
        XCTAssertEqual(loader.loadCount, 1)
        XCTAssertTrue(host.isLoaded(pluginID: manifest.id))
        XCTAssertEqual(host.loadedPluginIDs, [manifest.id])
        XCTAssertNotNil(first.voiceProvider)

        _ = try host.loadIfNeeded(pluginID: manifest.id)
        XCTAssertEqual(loader.loadCount, 1, "2 回目はキャッシュを返し、再実体化しない")
    }

    func testLoadUnknownPluginThrows() {
        let host = PluginHost(loader: SampleTonePluginLoader())
        XCTAssertThrowsError(try host.loadIfNeeded(pluginID: "no.such.plugin")) { error in
            XCTAssertEqual(error as? PluginError, .notRegistered(pluginID: "no.such.plugin"))
        }
    }

    // MARK: - ライセンス検証スタブ

    func testLicenseVerifierApprovesAndRejects() {
        let store = InMemoryLicenseStore()
        let verifier = InMemoryLicenseVerifier(store: store)
        store.issue(pluginID: SampleTonePlugin.pluginID,
                    licenseCode: SampleTonePlugin.licenseCode,
                    deviceID: SampleTonePlugin.deviceID)

        // 承認: 正しいコード × 正しいデバイス。書式ゆれ(小文字・ハイフン無し)も正規化して通る。
        XCTAssertEqual(verifier.verify(pluginID: SampleTonePlugin.pluginID,
                                       licenseCode: SampleTonePlugin.licenseCode,
                                       deviceID: SampleTonePlugin.deviceID), .valid)
        XCTAssertEqual(verifier.verify(pluginID: SampleTonePlugin.pluginID,
                                       licenseCode: "sampletone12345678",
                                       deviceID: SampleTonePlugin.deviceID), .valid)
        // 拒否: 別デバイス。
        XCTAssertEqual(verifier.verify(pluginID: SampleTonePlugin.pluginID,
                                       licenseCode: SampleTonePlugin.licenseCode,
                                       deviceID: "another-device"), .deviceMismatch)
        // 拒否: 未発行コード / 別プラグインのコード。
        XCTAssertEqual(verifier.verify(pluginID: SampleTonePlugin.pluginID,
                                       licenseCode: "WRONG-CODE-0000",
                                       deviceID: SampleTonePlugin.deviceID), .notFound)
        XCTAssertEqual(verifier.verify(pluginID: "other.plugin",
                                       licenseCode: SampleTonePlugin.licenseCode,
                                       deviceID: SampleTonePlugin.deviceID), .notFound)
        // 拒否: 空コード。
        XCTAssertEqual(verifier.verify(pluginID: SampleTonePlugin.pluginID,
                                       licenseCode: "  ",
                                       deviceID: SampleTonePlugin.deviceID), .invalidCode)
        // 平文は保持しない: ストアが持つのはハッシュ由来の件数だけ。
        XCTAssertEqual(store.count, 1)
        XCTAssertFalse(LicenseCode.sha256Hex(SampleTonePlugin.licenseCode).contains("SAMPLE"))
    }

    func testHostBlocksLicensedPluginWithoutValidLicense() throws {
        let store = InMemoryLicenseStore()
        let verifier = InMemoryLicenseVerifier(store: store)
        store.issue(pluginID: SampleTonePlugin.pluginID,
                    licenseCode: SampleTonePlugin.licenseCode,
                    deviceID: SampleTonePlugin.deviceID)
        let loader = SampleTonePluginLoader()
        let host = PluginHost(loader: loader, licenseVerifier: verifier,
                              deviceID: SampleTonePlugin.deviceID)
        host.register(manifest: SampleTonePlugin.manifest, directory: tempRoot)

        // コード未設定 → 拒否され、実体化もされない。
        XCTAssertThrowsError(try host.loadIfNeeded(pluginID: SampleTonePlugin.pluginID)) { error in
            XCTAssertEqual(error as? PluginError,
                           .licenseDenied(pluginID: SampleTonePlugin.pluginID, result: .notFound))
        }
        XCTAssertEqual(loader.loadCount, 0)

        // 間違ったコード → 拒否。
        host.setLicenseCode("WRONG-CODE-0000", forPluginID: SampleTonePlugin.pluginID)
        XCTAssertThrowsError(try host.loadIfNeeded(pluginID: SampleTonePlugin.pluginID))
        XCTAssertEqual(loader.loadCount, 0)

        // 正しいコード → 通る。
        host.setLicenseCode(SampleTonePlugin.licenseCode, forPluginID: SampleTonePlugin.pluginID)
        XCTAssertEqual(host.verifyLicense(forPluginID: SampleTonePlugin.pluginID), .valid)
        _ = try host.loadIfNeeded(pluginID: SampleTonePlugin.pluginID)
        XCTAssertEqual(loader.loadCount, 1)
    }

    // MARK: - 音声フック + エンドツーエンド

    func testVoiceProviderResolutionByEngineID() throws {
        var manifest = SampleTonePlugin.manifest
        manifest.requiresLicense = false
        let loader = SampleTonePluginLoader()
        let host = PluginHost(loader: loader)
        host.register(manifest: manifest, directory: tempRoot)

        // 未知の engine は nil / エラー(プラグイン未実体化のまま)。
        XCTAssertNil(try host.voiceProviderIfAvailable(forEngine: "voicevox"))
        XCTAssertThrowsError(try host.voiceProvider(forEngine: "voicevox")) { error in
            XCTAssertEqual(error as? PluginError, .noVoicePlugin(engineID: "voicevox"))
        }
        XCTAssertEqual(loader.loadCount, 0)

        var character = Character()
        character.engine = SampleTonePlugin.engineID
        let provider = try host.voiceProvider(for: character)
        XCTAssertTrue(provider is SampleToneVoiceProvider)
        XCTAssertEqual(loader.loadCount, 1)
    }

    func testEndToEndDiscoveryLicenseLazyLoadAndSynthesis() async throws {
        // 1) 探索: フォルダを作って manifest.json だけから登録する。
        try SampleTonePlugin.install(into: tempRoot)
        let discovery = PluginDiscovery.discover(in: [tempRoot])
        XCTAssertEqual(discovery.plugins.count, 1)
        XCTAssertTrue(discovery.failures.isEmpty)

        // 2) ライセンス: 発行済みコードをストアに用意し、ホストへ渡す。
        let store = InMemoryLicenseStore()
        store.issue(pluginID: SampleTonePlugin.pluginID,
                    licenseCode: SampleTonePlugin.licenseCode,
                    deviceID: SampleTonePlugin.deviceID)
        let loader = SampleTonePluginLoader()
        let host = PluginHost(loader: loader,
                              licenseVerifier: InMemoryLicenseVerifier(store: store),
                              deviceID: SampleTonePlugin.deviceID)
        host.register(discovery)
        host.setLicenseCode(SampleTonePlugin.licenseCode, forPluginID: SampleTonePlugin.pluginID)

        // 3) 遅延ロード: ここまではまだ実体化されていない。
        XCTAssertEqual(loader.loadCount, 0)
        XCTAssertFalse(host.isLoaded(pluginID: SampleTonePlugin.pluginID))

        // 4) 解決 + 合成: キャラの engine から VoiceProvider を引き、実際に WAV を作る。
        var character = Character()
        character.name = "サンプル"
        character.engine = SampleTonePlugin.engineID
        let provider = try host.voiceProvider(for: character)
        XCTAssertEqual(loader.loadCount, 1, "初回使用で初めて実体化される")
        XCTAssertTrue(host.isLoaded(pluginID: SampleTonePlugin.pluginID))

        let outDir = tempRoot.appendingPathComponent("out", isDirectory: true)
        let result = try await provider.synthesize(character: character, text: "こんにちは、プラグインです", in: outDir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.url.path))
        XCTAssertEqual(result.url.pathExtension, "wav")
        XCTAssertGreaterThan(result.duration, 0)
        let measured = try WavFile.duration(of: result.url)
        XCTAssertEqual(measured, result.duration, accuracy: 0.05)
        XCTAssertEqual(loader.lastProvider?.synthesizedTexts, ["こんにちは、プラグインです"])
    }
    // MARK: - 互換性チェックと接続点の不足ケース

    func testIncompatibleAppVersionBlocksLoad() throws {
        // 最小アプリバージョンが現行より新しいプラグインは、登録はできても実体化で弾く。
        var manifest = SampleTonePlugin.manifest
        manifest.requiresLicense = false
        manifest.minimumAppVersion = "2.0.0"
        let loader = SampleTonePluginLoader()
        let host = PluginHost(loader: loader, appVersion: "1.0.0")
        host.register(manifest: manifest, directory: tempRoot)
        XCTAssertEqual(host.registeredManifests.map(\.id), [manifest.id])

        XCTAssertThrowsError(try host.loadIfNeeded(pluginID: manifest.id)) { error in
            XCTAssertEqual(error as? PluginError,
                           .incompatibleAppVersion(pluginID: manifest.id, required: "2.0.0", current: "1.0.0"))
        }
        XCTAssertEqual(loader.loadCount, 0, "互換性で弾かれたらローダは呼ばれない")
        XCTAssertFalse(host.isLoaded(pluginID: manifest.id))

        // 音声解決経由でも同じエラーが伝播する。
        XCTAssertThrowsError(try host.voiceProvider(forEngine: SampleTonePlugin.engineID)) { error in
            XCTAssertEqual(error as? PluginError,
                           .incompatibleAppVersion(pluginID: manifest.id, required: "2.0.0", current: "1.0.0"))
        }
        XCTAssertEqual(loader.loadCount, 0)
    }

    func testVoiceProviderMissingThrows() throws {
        // マニフェストは音声エンジンを名乗るのに、本体が VoiceProvider を持たない場合。
        var manifest = SampleTonePlugin.manifest
        manifest.requiresLicense = false
        let loader = ClosurePluginLoader { manifest, directory in
            LoadedPlugin(manifest: manifest, directory: directory, voiceProvider: nil)
        }
        let host = PluginHost(loader: loader)
        host.register(manifest: manifest, directory: tempRoot)

        // 実体化そのものは成功する(プラグインは読み込まれる)。
        _ = try host.loadIfNeeded(pluginID: manifest.id)
        XCTAssertTrue(host.isLoaded(pluginID: manifest.id))

        XCTAssertThrowsError(try host.voiceProvider(forEngine: SampleTonePlugin.engineID)) { error in
            XCTAssertEqual(error as? PluginError, .voiceProviderMissing(pluginID: manifest.id))
        }
        // 投げない版は nil を返す(呼び出し側がコア既定の扱いに落とせる)。
        XCTAssertNil(try host.voiceProviderIfAvailable(forEngine: SampleTonePlugin.engineID))
    }

    // MARK: - ホスト解決プロバイダ → Core の台本生成/作り直し(接続点の E2E)

    func testHostResolvedProviderDrivesScriptTimelineAdd() async throws {
        try SampleTonePlugin.install(into: tempRoot)
        let discovery = PluginDiscovery.discover(in: [tempRoot])
        let store = InMemoryLicenseStore()
        store.issue(pluginID: SampleTonePlugin.pluginID,
                    licenseCode: SampleTonePlugin.licenseCode,
                    deviceID: SampleTonePlugin.deviceID)
        let loader = SampleTonePluginLoader()
        let host = PluginHost(loader: loader,
                              licenseVerifier: InMemoryLicenseVerifier(store: store),
                              deviceID: SampleTonePlugin.deviceID)
        host.register(discovery)
        host.setLicenseCode(SampleTonePlugin.licenseCode, forPluginID: SampleTonePlugin.pluginID)

        var project = Project.new()
        project.characters[0].engine = SampleTonePlugin.engineID
        let provider = try host.voiceProvider(for: project.characters[0])
        XCTAssertEqual(loader.loadCount, 1)

        // 解決したプロバイダを Core の台本生成へ渡すと、声クリップがタイムラインに並ぶ。
        let added = try await ScriptTimeline.add(lines: ["キャラ1: プラグイン経由です"],
                                                 to: &project, voice: provider, directory: tempRoot)
        XCTAssertEqual(added.count, 1)
        XCTAssertEqual(added[0].text, "プラグイン経由です")
        XCTAssertEqual(added[0].duration, 0.4, accuracy: 0.05)   // 音声 0.25 + 余白 0.15
        XCTAssertEqual(loader.lastProvider?.synthesizedTexts, ["プラグイン経由です"])
    }

    func testHostResolvedProviderRegeneratesClip() async throws {
        var manifest = SampleTonePlugin.manifest
        manifest.requiresLicense = false
        let loader = SampleTonePluginLoader()
        let host = PluginHost(loader: loader)
        host.register(manifest: manifest, directory: tempRoot)
        let provider = try host.voiceProvider(forEngine: SampleTonePlugin.engineID)

        let project = Project.new()
        var clip = Clip()
        clip.type = .voice
        clip.charId = project.characters[0].id
        clip.text = "あ"
        clip.offset = 0.7
        clip.duration = 9
        clip.src = "/old.wav"
        try await regenerateVoice(clip: &clip, project: project, provider: provider)
        XCTAssertEqual(clip.duration, 0.4, accuracy: 0.05)
        XCTAssertNotEqual(clip.src, "/old.wav")
        XCTAssertEqual(loader.lastProvider?.synthesizedTexts, ["あ"])
    }
}
