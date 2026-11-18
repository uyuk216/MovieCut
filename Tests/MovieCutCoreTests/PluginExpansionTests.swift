import XCTest
import CoreGraphics
import CoreImage
@testable import MovieCutCore

/// プラグイン機構の拡張(第2波バッチF / 監査#76): エフェクト種別と書き出し種別のテスト。
/// 登録・解決・適用(サンプルプラグイン経由)と、未登録時の従来同一性を確認する。
final class PluginExpansionTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("mc-pluginx-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
    }

    /// アプリ(AppServices.makePluginHost)と同じ組み込み登録を作る。
    private func makeBuiltinHost() -> PluginHost {
        let dir = tempRoot!
        let loader = BuiltinPluginLoader([
            InvertEffectPlugin.manifest.id: { LoadedPlugin(manifest: InvertEffectPlugin.manifest, directory: dir, effectProvider: InvertEffectProvider()) },
            PosterizeEffectPlugin.manifest.id: { LoadedPlugin(manifest: PosterizeEffectPlugin.manifest, directory: dir, effectProvider: PosterizeEffectProvider()) },
            GIFExportPlugin.manifest.id: { LoadedPlugin(manifest: GIFExportPlugin.manifest, directory: dir, exportBackend: GIFExportBackend(options: GIFOptions(fps: 5, maxWidth: 160))) },
            ProjectInfoExportPlugin.manifest.id: { LoadedPlugin(manifest: ProjectInfoExportPlugin.manifest, directory: dir, exportBackend: ProjectInfoExportBackend()) },
        ])
        let host = PluginHost(loader: loader)
        host.register(manifest: InvertEffectPlugin.manifest, directory: dir)
        host.register(manifest: PosterizeEffectPlugin.manifest, directory: dir)
        host.register(manifest: GIFExportPlugin.manifest, directory: dir)
        host.register(manifest: ProjectInfoExportPlugin.manifest, directory: dir)
        return host
    }

    // MARK: - マニフェスト(新フィールドの互換)

    func testManifestEffectAndExportIDsRoundTrip() throws {
        for manifest in [InvertEffectPlugin.manifest, PosterizeEffectPlugin.manifest, GIFExportPlugin.manifest, ProjectInfoExportPlugin.manifest] {
            let decoded = try JSONDecoder().decode(PluginManifest.self, from: JSONEncoder().encode(manifest))
            XCTAssertEqual(decoded, manifest)
        }
        XCTAssertTrue(InvertEffectPlugin.manifest.provides(.effect))
        XCTAssertTrue(InvertEffectPlugin.manifest.handlesEffect("plugin.invert"))
        XCTAssertTrue(InvertEffectPlugin.manifest.handlesEffect(" PLUGIN.INVERT "))
        XCTAssertFalse(InvertEffectPlugin.manifest.handlesEffect("plugin.posterize"))
        XCTAssertFalse(InvertEffectPlugin.manifest.handlesVoiceEngine("plugin.invert"), "フックが違うものは担当しない")
        XCTAssertTrue(GIFExportPlugin.manifest.provides(.exporter))
        XCTAssertTrue(GIFExportPlugin.manifest.handlesExportFormat("gif"))
        XCTAssertTrue(GIFExportPlugin.manifest.handlesExportFormat("GIF"))
        XCTAssertFalse(GIFExportPlugin.manifest.handlesExportFormat("mp4"))
    }

    func testManifestWithoutNewKeysDecodesToEmptyIDs() throws {
        // 旧形式(新キーの無い manifest.json)もそのまま読める(追加方式の互換)。
        let json = #"{"id":"a.b.c","name":"旧形式","version":"0.1.0","hooks":["effect"],"entryPoint":"E"}"#
        let decoded = try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.effectIDs, [])
        XCTAssertEqual(decoded.exportFormatIDs, [])
        XCTAssertFalse(decoded.handlesEffect("plugin.invert"))
    }

    func testBuiltinManifestJSONIsDiscoverable() throws {
        // manifestJSON() をフォルダに置けば Discovery → 登録まで通る(音声プラグインと同じ流儀)。
        let folder = tempRoot.appendingPathComponent("InvertEffectPlugin", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try InvertEffectPlugin.manifestJSON().write(to: folder.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        let result = PluginDiscovery.discover(in: [tempRoot])
        XCTAssertEqual(result.plugins.map(\.manifest.id), [InvertEffectPlugin.pluginID])
        XCTAssertEqual(result.plugins.first?.manifest.effectIDs, [InvertEffectPlugin.effectID])
    }

    // MARK: - ホスト解決(エフェクト)

    func testEffectProviderResolutionIsLazyAndCached() throws {
        let host = makeBuiltinHost()
        XCTAssertFalse(host.isLoaded(pluginID: InvertEffectPlugin.pluginID), "登録だけでは実体化しない")
        let provider = try host.effectProvider(forEffectID: "plugin.invert")
        XCTAssertTrue(provider is InvertEffectProvider)
        XCTAssertTrue(host.isLoaded(pluginID: InvertEffectPlugin.pluginID))
        XCTAssertFalse(host.isLoaded(pluginID: PosterizeEffectPlugin.pluginID), "使っていないプラグインは実体化しない")
        // 投げない版・大文字小文字ゆれ
        XCTAssertNotNil(try host.effectProviderIfAvailable(forEffectID: "PLUGIN.POSTERIZE"))
        // 記述子一覧
        XCTAssertEqual(host.effectDescriptors().map(\.id), [InvertEffectPlugin.effectID, PosterizeEffectPlugin.effectID])
    }

    func testEffectResolutionFailures() throws {
        let host = makeBuiltinHost()
        XCTAssertNil(try host.effectProviderIfAvailable(forEffectID: "plugin.unknown"))
        XCTAssertThrowsError(try host.effectProvider(forEffectID: "plugin.unknown")) { error in
            XCTAssertEqual(error as? PluginError, .noEffectPlugin(effectID: "plugin.unknown"))
        }
        // マニフェストは名乗るのに本体がプロバイダを持たない場合。
        var manifest = InvertEffectPlugin.manifest
        manifest.requiresLicense = false
        let bare = PluginHost(loader: ClosurePluginLoader { m, d in LoadedPlugin(manifest: m, directory: d) })
        bare.register(manifest: manifest, directory: tempRoot)
        XCTAssertThrowsError(try bare.effectProvider(forEffectID: InvertEffectPlugin.effectID)) { error in
            XCTAssertEqual(error as? PluginError, .effectProviderMissing(pluginID: manifest.id))
        }
        XCTAssertNil(try bare.effectProviderIfAvailable(forEffectID: InvertEffectPlugin.effectID))
    }

    func testEffectPluginsDoNotTouchVoiceResolution() throws {
        // エフェクト/書き出しプラグインだけのホストでは、音声解決は従来どおり「無し」になる。
        let host = makeBuiltinHost()
        XCTAssertNil(try host.voiceProviderIfAvailable(forEngine: "voicevox"))
        XCTAssertThrowsError(try host.voiceProvider(forEngine: "voicevox")) { error in
            XCTAssertEqual(error as? PluginError, .noVoicePlugin(engineID: "voicevox"))
        }
    }

    // MARK: - エフェクトの解決と適用(EffectPipeline 統合経路)

    private func solidCIImage(r: Double, g: Double, b: Double, size: Int = 40) -> CIImage {
        CIImage(color: CIColor(red: r, green: g, blue: b, alpha: 1)).cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
    }

    private func centerRGB(_ image: CIImage) -> [Int] {
        let rect = image.extent
        let cg = EffectPipeline.makeImage(image, from: rect)!
        var d = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let ctx = CGContext(data: &d, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let i = ((cg.height / 2) * cg.width + cg.width / 2) * 4
        return [Int(d[i]), Int(d[i + 1]), Int(d[i + 2])]
    }

    private func clip(effects: [Effect]) -> Clip {
        var c = Clip(); c.type = .image; c.start = 0; c.duration = 4
        c.effects = effects
        return c
    }

    func testInvertPluginEffectAppliesThroughPipeline() {
        let providers: [any VideoEffectProviding] = [InvertEffectProvider()]
        let c = clip(effects: [Effect(kind: InvertEffectPlugin.effectID, params: ["amount": 1])])
        let resolved = EffectPipeline.resolveAll(c, atClipTime: 0, pluginProviders: providers)
        XCTAssertEqual(resolved.count, 1)
        guard case .plugin(let p) = resolved[0] else { return XCTFail("プラグインとして解決されるはず") }
        XCTAssertEqual(p.effectID, InvertEffectPlugin.effectID)
        XCTAssertEqual(p.v("amount"), 1, accuracy: 1e-9)

        let bounds = CGRect(x: 0, y: 0, width: 40, height: 40)
        let out = EffectPipeline.apply(solidCIImage(r: 200.0 / 255, g: 30.0 / 255, b: 60.0 / 255),
                                       effects: resolved, bounds: bounds, scale: 1, pluginProviders: providers)
        let rgb = centerRGB(out)
        XCTAssertEqual(rgb[0], 55, accuracy: 3)
        XCTAssertEqual(rgb[1], 225, accuracy: 3)
        XCTAssertEqual(rgb[2], 195, accuracy: 3)
    }

    func testPosterizePluginEffectQuantizes() {
        let providers: [any VideoEffectProviding] = [PosterizeEffectProvider()]
        let c = clip(effects: [Effect(kind: PosterizeEffectPlugin.effectID, params: ["levels": 4])])
        let resolved = EffectPipeline.resolveAll(c, atClipTime: 0, pluginProviders: providers)
        XCTAssertEqual(resolved.count, 1)
        let bounds = CGRect(x: 0, y: 0, width: 40, height: 40)
        let out = EffectPipeline.apply(solidCIImage(r: 0.4, g: 0.4, b: 0.4), effects: resolved, bounds: bounds, scale: 1, pluginProviders: providers)
        let rgb = centerRGB(out)
        // 4 階調なら各チャンネルは 0/85/170/255 のいずれか近くになる。
        for v in rgb { XCTAssertTrue([0, 85, 170, 255].contains { abs($0 - v) <= 3 }, "got \(rgb)") }
        // 階調 32(上限)は恒等として解決から落ちる。
        let maxed = clip(effects: [Effect(kind: PosterizeEffectPlugin.effectID, params: ["levels": 32])])
        XCTAssertTrue(EffectPipeline.resolveAll(maxed, atClipTime: 0, pluginProviders: providers).isEmpty)
    }

    func testPluginEffectIdentityKeyframeAndClamp() {
        let providers: [any VideoEffectProviding] = [InvertEffectProvider()]
        // 強さ 0 は恒等 → 解決から落ちる。
        let zero = clip(effects: [Effect(kind: InvertEffectPlugin.effectID, params: ["amount": 0])])
        XCTAssertTrue(EffectPipeline.resolveAll(zero, atClipTime: 0, pluginProviders: providers).isEmpty)
        // 範囲外の値は記述子の範囲に収まる。
        let over = clip(effects: [Effect(kind: InvertEffectPlugin.effectID, params: ["amount": 5])])
        let resolvedOver = EffectPipeline.resolveAll(over, atClipTime: 0, pluginProviders: providers)
        guard case .plugin(let p) = resolvedOver.first else { return XCTFail() }
        XCTAssertEqual(p.v("amount"), 1, accuracy: 1e-9)
        // キーフレーム補間も内蔵と同じ "fx.<番号>.<引数名>" で効く。
        var kf = clip(effects: [Effect(kind: InvertEffectPlugin.effectID, params: ["amount": 0])])
        kf.keyframes["fx.0.amount"] = [Keyframe(t: 0, v: 0), Keyframe(t: 2, v: 1)]
        let mid = EffectPipeline.resolveAll(kf, atClipTime: 1, pluginProviders: providers)
        guard case .plugin(let pm) = mid.first else { return XCTFail() }
        XCTAssertEqual(pm.v("amount"), 0.5, accuracy: 1e-9)
    }

    func testResolveAllPreservesOrderAcrossBuiltinAndPlugin() {
        let providers: [any VideoEffectProviding] = [InvertEffectProvider(), PosterizeEffectProvider()]
        let c = clip(effects: [
            Effect(.brightness),
            Effect(kind: InvertEffectPlugin.effectID, params: ["amount": 1]),
            Effect(kind: PosterizeEffectPlugin.effectID, params: ["levels": 4]),
        ])
        let resolved = EffectPipeline.resolveAll(c, atClipTime: 0, pluginProviders: providers)
        XCTAssertEqual(resolved.count, 3)
        guard case .builtin(let b) = resolved[0] else { return XCTFail("先頭は内蔵の明るさ") }
        XCTAssertEqual(b.kind, .brightness)
        guard case .plugin(let p1) = resolved[1], case .plugin(let p2) = resolved[2] else { return XCTFail("後続はプラグイン") }
        XCTAssertEqual(p1.effectID, InvertEffectPlugin.effectID)
        XCTAssertEqual(p2.effectID, PosterizeEffectPlugin.effectID)
        XCTAssertTrue(c.hasActivePluginEffect(effectIDs: [InvertEffectPlugin.effectID]))
        XCTAssertFalse(c.hasActivePluginEffect(effectIDs: ["plugin.unknown"]))
    }

    func testUnregisteredPluginEffectIsIgnoredLikeUnknownKind() {
        // プラグイン未登録時は従来と完全同一: 未知の種類として何もしない。
        let c = clip(effects: [Effect(kind: InvertEffectPlugin.effectID, params: ["amount": 1])])
        XCTAssertTrue(EffectPipeline.resolveAll(c, atClipTime: 0, pluginProviders: []).isEmpty)
        XCTAssertTrue(EffectPipeline.resolve(c, atClipTime: 0).isEmpty, "従来の resolve もプラグイン種別を拾わない")
        // 内蔵だけのクリップでは resolveAll(プラグインなし) == resolve。
        let builtinOnly = clip(effects: [Effect(.brightness), Effect(.sepia)])
        let viaAll = EffectPipeline.resolveAll(builtinOnly, atClipTime: 0, pluginProviders: [])
        let viaClassic = EffectPipeline.resolve(builtinOnly, atClipTime: 0)
        XCTAssertEqual(viaAll.count, viaClassic.count)
        for (a, b) in zip(viaAll, viaClassic) {
            guard case .builtin(let r) = a else { return XCTFail() }
            XCTAssertEqual(r, b)
        }
        // 内蔵だが「何もしない値」のエフェクトは、プラグイン側へ回らない(二重適用防止)。
        let identityBuiltin = clip(effects: [Effect(.brightness)])
        var dim = identityBuiltin; dim.effects[0].params["amount"] = 0
        XCTAssertTrue(EffectPipeline.resolveAll(dim, atClipTime: 0, pluginProviders: [InvertEffectProvider()]).isEmpty)
    }

    // MARK: - ホスト解決(書き出し)

    func testExportBackendResolution() throws {
        let host = makeBuiltinHost()
        XCTAssertFalse(host.isLoaded(pluginID: GIFExportPlugin.pluginID))
        let backend = try host.exportBackend(forFormat: "gif")
        XCTAssertTrue(backend is GIFExportBackend)
        XCTAssertTrue(host.isLoaded(pluginID: GIFExportPlugin.pluginID))
        XCTAssertNil(try host.exportBackendIfAvailable(forFormat: "mp4"))
        XCTAssertThrowsError(try host.exportBackend(forFormat: "mp4")) { error in
            XCTAssertEqual(error as? PluginError, .noExportPlugin(formatID: "mp4"))
        }
        XCTAssertEqual(host.exportFormatDescriptors().map(\.id), [GIFExportPlugin.formatID, ProjectInfoExportPlugin.formatID])
        XCTAssertEqual(host.exportFormatDescriptors().map(\.fileExtension), ["gif", "json"])

        var manifest = GIFExportPlugin.manifest
        manifest.requiresLicense = false
        let bare = PluginHost(loader: ClosurePluginLoader { m, d in LoadedPlugin(manifest: m, directory: d) })
        bare.register(manifest: manifest, directory: tempRoot)
        XCTAssertThrowsError(try bare.exportBackend(forFormat: "gif")) { error in
            XCTAssertEqual(error as? PluginError, .exportBackendMissing(pluginID: manifest.id))
        }
    }

    // MARK: - 書き出しの適用(サンプル経由)

    private func textProject() -> Project {
        var p = Project.new()
        p.width = 320; p.height = 180; p.fps = 30
        var t = Clip(); t.type = .text; t.text = "GIF"; t.start = 0; t.duration = 1; t.fontSize = 60; t.x = 0.5; t.y = 0.5
        p.tracks[4].clips.append(t)
        return p
    }

    func testProjectInfoExportViaPluginJob() async throws {
        let host = makeBuiltinHost()
        let p = textProject()
        let out = tempRoot.appendingPathComponent("info.json")
        let result = try await PluginExportJob.runIfAvailable(host: host, formatID: "project-json", project: p, to: out)
        let r = try XCTUnwrap(result, "担当プラグインがあるので nil にならない")
        XCTAssertEqual(r.formatID, "project-json")
        XCTAssertGreaterThan(r.bytes, 0)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: out)) as? [String: Any]
        XCTAssertEqual(json?["width"] as? Int, 320)
        XCTAssertEqual(json?["height"] as? Int, 180)
        XCTAssertEqual(json?["clips"] as? Int, p.tracks.reduce(0) { $0 + $1.clips.count })
        XCTAssertEqual(json?["duration"] as? Double ?? -1, p.endTime, accuracy: 1e-9)
        // 決定的: 同じプロジェクトからは同じバイト列。
        let out2 = tempRoot.appendingPathComponent("info2.json")
        _ = try await PluginExportJob.runIfAvailable(host: host, formatID: "project-json", project: p, to: out2)
        XCTAssertEqual(try Data(contentsOf: out), try Data(contentsOf: out2))
    }

    func testGIFExportViaPluginJobWritesRealGIF() async throws {
        let host = makeBuiltinHost()
        let out = tempRoot.appendingPathComponent("via-plugin.gif")
        let result = try await PluginExportJob.runIfAvailable(host: host, formatID: "gif", project: textProject(), to: out)
        let r = try XCTUnwrap(result)
        XCTAssertEqual(r.formatID, "gif")
        XCTAssertGreaterThan(r.bytes, 0)
        let head = try Data(contentsOf: out).prefix(4)
        XCTAssertEqual(String(decoding: head, as: UTF8.self), "GIF8", "実 GIF が書けている")
    }

    func testPluginExportJobReturnsNilForUnknownFormat() async throws {
        // 未登録の形式は nil(呼び出し側が内蔵 ExportJob へ落とす合図)。
        let host = makeBuiltinHost()
        let out = tempRoot.appendingPathComponent("never.mp4")
        let result = try await PluginExportJob.runIfAvailable(host: host, formatID: "mp4", project: textProject(), to: out)
        XCTAssertNil(result)
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
    }

    func testExportBackendRejectsForeignFormatID() async throws {
        // バックエンドを直接呼んでも、担当外の形式は弾く。
        let backend = ProjectInfoExportBackend()
        do {
            _ = try await backend.export(formatID: "gif", project: textProject(), assets: RenderAssets(), range: nil, to: tempRoot.appendingPathComponent("x.json"), progress: nil)
            XCTFail("担当外はエラーのはず")
        } catch let error as PluginError {
            XCTAssertEqual(error, .noExportPlugin(formatID: "gif"))
        }
    }
}
