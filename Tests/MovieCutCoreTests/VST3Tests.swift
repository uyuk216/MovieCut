import XCTest
import AVFoundation
@testable import MovieCutCore

/// VST3(W3-07/#67)の到達範囲: スキャン(検出のみ)、境界(未ロード時はバイパス)、
/// 保存形式(スロットが無ければ従来とバイト一致)の確認。実プラグインは使わない
/// (この Mac には VST3 が入っていないため、フィクスチャの偽バンドルで検証する)。
final class VST3Tests: XCTestCase {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vst3-tests-\(UUID().uuidString)")
    override func setUpWithError() throws { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    // MARK: フィクスチャ(偽の .vst3 バンドル)

    /// ビッグエンディアンの UInt32 をバイト列にする。
    func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)] }

    /// ファット Mach-O のヘッダ(実体は無く、ヘッダ表だけ正しいもの)。
    func fatMachO(_ archs: [(cpu: UInt32, sub: UInt32)]) -> Data {
        var b: [UInt8] = [0xCA, 0xFE, 0xBA, 0xBE] + be32(UInt32(archs.count))
        for a in archs { b += be32(a.cpu) + be32(a.sub) + be32(4096) + be32(1024) + be32(12) }
        b += [UInt8](repeating: 0, count: 256)
        return Data(b)
    }

    /// 単一(arm64)Mach-O 64 のヘッダ。
    func thinArm64MachO() -> Data {
        var b: [UInt8] = [0xCF, 0xFA, 0xED, 0xFE] + le32(0x0100_000C) + le32(0) + le32(2) + le32(0)
        b += [UInt8](repeating: 0, count: 256)
        return Data(b)
    }

    @discardableResult
    func makeBundle(_ folder: String, plist: [String: Any]?, executable: String?, binary: Data?,
                    moduleInfo: String? = nil) throws -> URL {
        let root = tmp.appendingPathComponent(folder, isDirectory: true)
        let contents = root.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        if let plist {
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
        }
        if let executable {
            let macos = contents.appendingPathComponent("MacOS", isDirectory: true)
            try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
            if let binary { try binary.write(to: macos.appendingPathComponent(executable)) }
        }
        if let moduleInfo {
            let res = contents.appendingPathComponent("Resources", isDirectory: true)
            try FileManager.default.createDirectory(at: res, withIntermediateDirectories: true)
            try Data(moduleInfo.utf8).write(to: res.appendingPathComponent("moduleinfo.json"))
        }
        return root
    }

    func standardPlist(name: String = "TestVerb", id: String = "com.example.testverb",
                       version: String = "1.2.3", exe: String = "TestVerb") -> [String: Any] {
        ["CFBundleName": name, "CFBundleIdentifier": id, "CFBundleShortVersionString": version, "CFBundleExecutable": exe]
    }

    // MARK: Mach-O 解釈

    func testMachOArchitecturesFatAndThin() {
        XCTAssertEqual(VST3Scanner.machOArchitectures(fatMachO([(0x0100_000C, 0), (0x0100_0007, 3)])), ["arm64", "x86_64"])
        XCTAssertEqual(VST3Scanner.machOArchitectures(fatMachO([(0x0100_000C, 2)])), ["arm64e"], "亜種 2 は arm64e")
        XCTAssertEqual(VST3Scanner.machOArchitectures(thinArm64MachO()), ["arm64"])
        XCTAssertEqual(VST3Scanner.machOArchitectures(Data("ただのテキスト".utf8)), [])
        XCTAssertEqual(VST3Scanner.machOArchitectures(Data()), [])
    }

    // MARK: スキャン

    func testScanDetectsBundleAndReadsMetadata() throws {
        let moduleInfo = #"{"Name":"TestVerb","Vendor":"Example","Version":"1.2.3","SDKVersion":"VST 3.7","Classes":[{"Category":"Audio Module Class","Name":"TestVerb","Vendor":"Example","Version":"1.2.3","CID":"ABC"}]}"#
        try makeBundle("TestVerb.vst3", plist: standardPlist(), executable: "TestVerb",
                       binary: fatMachO([(0x0100_000C, 0), (0x0100_0007, 3)]), moduleInfo: moduleInfo)
        // .vst3 でないものは無視される
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("Other.component"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: tmp.appendingPathComponent("memo.txt"))

        let result = VST3Scanner.scan(directories: [tmp])
        XCTAssertEqual(result.plugins.count, 1)
        XCTAssertTrue(result.failures.isEmpty)
        let info = result.plugins[0]
        XCTAssertEqual(info.name, "TestVerb")
        XCTAssertEqual(info.bundleIdentifier, "com.example.testverb")
        XCTAssertEqual(info.version, "1.2.3")
        XCTAssertEqual(info.architectures, ["arm64", "x86_64"])
        XCTAssertTrue(info.hasUsableStructure, "\(info.issues)")
        XCTAssertTrue(info.supportsHostArchitecture)
        XCTAssertEqual(info.moduleVendor, "Example")
        XCTAssertEqual(info.moduleClasses.first?.isAudioModule, true)
        XCTAssertTrue(info.declaresAudioModule)
        XCTAssertEqual(info.slotIdentifier, "com.example.testverb")
        XCTAssertEqual(info.audioEffectID, "vst3.com.example.testverb")
        XCTAssertEqual(result.plugin(forSlotIdentifier: "com.example.testverb")?.name, "TestVerb")
    }

    func testScanBrokenBundlesReportIssuesWithoutFailingOthers() throws {
        try makeBundle("Good.vst3", plist: standardPlist(name: "Good", id: "com.example.good", exe: "Good"),
                       executable: "Good", binary: thinArm64MachO())
        // 実行ファイルが無い
        try makeBundle("NoBinary.vst3", plist: standardPlist(name: "NoBinary", id: "com.example.nob", exe: "NoBinary"),
                       executable: nil, binary: nil)
        // Info.plist が無い(名前はフォルダ名に落ちる)
        try makeBundle("NoPlist.vst3", plist: nil, executable: "NoPlist", binary: thinArm64MachO())
        // 実行ファイルが Mach-O でない
        try makeBundle("NotMachO.vst3", plist: standardPlist(name: "NotMachO", id: "com.example.nm", exe: "NotMachO"),
                       executable: "NotMachO", binary: Data("テキスト".utf8))

        let result = VST3Scanner.scan(directories: [tmp])
        XCTAssertEqual(result.plugins.count, 4)
        XCTAssertEqual(result.usablePlugins.map { $0.name }, ["Good"])
        let noBinary = result.plugins.first { $0.name == "NoBinary" }
        XCTAssertTrue(noBinary?.issues.contains { $0.contains("実行ファイルが無い") } ?? false, "\(noBinary?.issues ?? [])")
        let noPlist = result.plugins.first { $0.bundleURL.lastPathComponent == "NoPlist.vst3" }
        XCTAssertEqual(noPlist?.name, "NoPlist")
        XCTAssertTrue(noPlist?.issues.contains { $0.contains("Info.plist") } ?? false)
        let notMachO = result.plugins.first { $0.name == "NotMachO" }
        XCTAssertEqual(notMachO?.architectures, [])
        XCTAssertFalse(notMachO?.hasUsableStructure ?? true)
    }

    func testScanMissingDirectoryIsFailureAndStandardScanIsQuiet() {
        let missing = tmp.appendingPathComponent("does-not-exist", isDirectory: true)
        let strict = VST3Scanner.scan(directories: [missing])
        XCTAssertTrue(strict.plugins.isEmpty)
        XCTAssertEqual(strict.failures.count, 1)
        XCTAssertEqual(strict.failures.first?.url, missing)
        // 標準の置き場が無いのは普通の状態なので、例外にも失敗の山にもしない(件数は環境依存で検証しない)
        _ = VST3Scanner.scanStandard()
        XCTAssertFalse(VST3Scanner.standardDirectories().contains { !FileManager.default.fileExists(atPath: $0.path) })
    }

    func testScanIntelOnlyBundleDoesNotSupportHostOnArm() throws {
        try makeBundle("Intel.vst3", plist: standardPlist(name: "Intel", id: "com.example.intel", exe: "Intel"),
                       executable: "Intel", binary: fatMachO([(0x0100_0007, 3)]))
        let info = try XCTUnwrap(VST3Scanner.scan(directories: [tmp]).plugins.first)
        XCTAssertEqual(info.architectures, ["x86_64"])
        #if arch(arm64)
        XCTAssertFalse(info.supportsHostArchitecture)
        #else
        XCTAssertTrue(info.supportsHostArchitecture)
        #endif
    }

    // MARK: 境界(未ロード時の扱い)

    func testAvailabilityIsHonestAboutProcessing() {
        XCTAssertFalse(VST3HostAvailability.current.canProcessAudio)
        XCTAssertTrue(VST3HostAvailability.current.userFacingNote.contains("検出のみ"))
        XCTAssertTrue(VST3HostAvailability.current.userFacingNote.contains("バイパス"))
    }

    func testBypassProcessorLeavesBuffersByteIdentical() {
        let p = BypassAudioEffectProcessor(effectID: "vst3.com.example.testverb", reason: "test")
        var l: [Float] = [0.5, -0.25, 0.125, 1, -1]
        var r: [Float] = [0.1, 0.2, 0.3, 0.4, 0.5]
        let l0 = l, r0 = r
        l.withUnsafeMutableBufferPointer { lp in
            r.withUnsafeMutableBufferPointer { rp in
                p.process(left: lp.baseAddress!, right: rp.baseAddress!, frames: 5)
            }
        }
        XCTAssertEqual(l, l0)
        XCTAssertEqual(r, r0)
        XCTAssertEqual(p.processedFrames, 5)
        XCTAssertEqual(p.processCalls, 1)
        p.reset()
        XCTAssertEqual(p.processedFrames, 0)
    }

    func testVST3ProviderDescriptorsAndBypass() throws {
        try makeBundle("TestVerb.vst3", plist: standardPlist(), executable: "TestVerb", binary: thinArm64MachO())
        try makeBundle("Broken.vst3", plist: standardPlist(name: "Broken", id: "com.example.broken", exe: "Broken"),
                       executable: nil, binary: nil)
        let provider = VST3EffectProvider(scanResult: VST3Scanner.scan(directories: [tmp]))
        XCTAssertEqual(provider.audioEffectDescriptors.map { $0.id }, ["vst3.com.example.testverb"], "構造が揃ったものだけ並べる")
        XCTAssertEqual(provider.audioEffectDescriptors.first?.label, "TestVerb(VST3)")
        let processor = provider.makeProcessor(effectID: "vst3.com.example.testverb", sampleRate: 48000, values: [:])
        let bypass = try XCTUnwrap(processor as? BypassAudioEffectProcessor)
        XCTAssertEqual(bypass.reason, VST3HostAvailability.current.bypassReason)
        XCTAssertNil(provider.makeProcessor(effectID: "vst3.unknown", sampleRate: 48000, values: [:]))
    }

    // MARK: プラグイン機構への統合(音声エフェクト種別)

    func testManifestAudioEffectHookBackwardCompatibility() throws {
        // 旧形式(audioEffectIDs 無し)は空として読める
        let old = #"{"id":"jp.example.old","name":"Old","version":"1.0.0","hooks":["voice"],"entryPoint":"Old","voiceEngineIDs":["voicevox"]}"#
        let m = try JSONDecoder().decode(PluginManifest.self, from: Data(old.utf8))
        XCTAssertEqual(m.audioEffectIDs, [])
        XCTAssertFalse(m.handlesAudioEffect("vst3.x"))
        // 新形式
        let manifest = PluginManifest(id: "jp.example.vst3host", name: "VST3Host", version: "1.0.0",
                                      hooks: [.audioEffect], entryPoint: "Host", audioEffectIDs: ["vst3.com.example.testverb"])
        XCTAssertTrue(manifest.provides(.audioEffect))
        XCTAssertTrue(manifest.handlesAudioEffect("VST3.COM.EXAMPLE.TESTVERB"), "大文字小文字は区別しない")
        let roundTrip = try JSONDecoder().decode(PluginManifest.self, from: JSONEncoder().encode(manifest))
        XCTAssertEqual(roundTrip, manifest)
    }

    func testPluginHostResolvesAudioEffectProvider() throws {
        let info = VST3BundleInfo(bundleURL: tmp.appendingPathComponent("TestVerb.vst3"),
                                  name: "TestVerb", bundleIdentifier: "com.example.testverb",
                                  version: "1.2.3", executableName: "TestVerb",
                                  executableURL: tmp.appendingPathComponent("TestVerb.vst3/Contents/MacOS/TestVerb"),
                                  architectures: ["arm64"])
        let manifest = PluginManifest(id: "jp.example.vst3host", name: "VST3Host", version: "1.0.0",
                                      hooks: [.audioEffect], entryPoint: "Host", audioEffectIDs: [info.audioEffectID])
        let dir = tmp.appendingPathComponent("host-plugin", isDirectory: true)
        let host = PluginHost(loader: ClosurePluginLoader { m, d in
            LoadedPlugin(manifest: m, directory: d, audioEffectProvider: VST3EffectProvider(plugins: [info]))
        })
        host.register(manifest: manifest, directory: dir)

        XCTAssertNil(try host.audioEffectProviderIfAvailable(forAudioEffectID: "vst3.unknown"))
        let provider = try XCTUnwrap(try host.audioEffectProviderIfAvailable(forAudioEffectID: info.audioEffectID))
        XCTAssertTrue(provider.handlesAudioEffect(info.audioEffectID))
        XCTAssertEqual(host.audioEffectDescriptors().map { $0.id }, [info.audioEffectID])
        XCTAssertThrowsError(try host.audioEffectProvider(forAudioEffectID: "vst3.unknown")) {
            XCTAssertEqual($0 as? PluginError, .noAudioEffectPlugin(effectID: "vst3.unknown"))
        }

        // プロバイダを持たないプラグインは「見つかったが持っていない」で区別する
        let emptyManifest = PluginManifest(id: "jp.example.empty", name: "Empty", version: "1.0.0",
                                           hooks: [.audioEffect], entryPoint: "Empty", audioEffectIDs: ["vst3.empty"])
        let host2 = PluginHost(loader: ClosurePluginLoader { m, d in LoadedPlugin(manifest: m, directory: d) })
        host2.register(manifest: emptyManifest, directory: dir)
        XCTAssertThrowsError(try host2.audioEffectProvider(forAudioEffectID: "vst3.empty")) {
            XCTAssertEqual($0 as? PluginError, .audioEffectProviderMissing(pluginID: "jp.example.empty"))
        }
    }

    // MARK: 保存形式(AudioFx.vst3)

    func testNoVST3WritesNothingAndMatchesPlain() throws {
        let plain = try JSONEncoder().encode(AudioFx())
        let withEmpty = try JSONEncoder().encode(AudioFx(vst3: []))
        XCTAssertEqual(plain, withEmpty, "空のスロット配列は従来とバイト一致")
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("vst3"))
    }

    func testVST3SlotRoundTripAndUnknownKeysKept() throws {
        let src = #"{"vst3":[{"bundleId":"com.example.testverb","name":"TestVerb","futureKey":9,"params":{"gain":0.5}}]}"#
        let fx = try JSONDecoder().decode(AudioFx.self, from: Data(src.utf8))
        XCTAssertEqual(fx.vst3Slots.count, 1)
        XCTAssertEqual(fx.vst3Slots[0].bundleID, "com.example.testverb")
        XCTAssertEqual(fx.vst3Slots[0].displayName, "TestVerb")
        XCTAssertEqual(fx.vst3Slots[0].params?["gain"], 0.5)
        XCTAssertEqual(fx.vst3Slots[0].processingStatus, .notImplemented)
        let out = String(decoding: try JSONEncoder().encode(fx), as: UTF8.self)
        XCTAssertTrue(out.contains("futureKey"), "知らないキーは書き戻す: \(out)")
        let back = try JSONDecoder().decode(AudioFx.self, from: Data(out.utf8))
        XCTAssertEqual(back, fx)
    }

    func testVST3SlotOnlyFxIsStoredButNeverActive() throws {
        var fx = AudioFx(vst3: [AudioFx.VST3Slot(bundleID: "com.example.testverb", name: "TestVerb")])
        XCTAssertFalse(fx.isEmpty, "スロットだけでもファイルに残す")
        XCTAssertFalse(fx.isActive, "処理未実装なので音には効かない")
        XCTAssertFalse(fx.hasChain)
        XCTAssertEqual(fx.cacheToken, "", "キャッシュ鍵も変えない(音が同じため)")
        XCTAssertEqual(fx.enabledVST3Slots.count, 1)
        fx.vst3?[0].enabled = false
        XCTAssertTrue(fx.enabledVST3Slots.isEmpty)
        let out = String(decoding: try JSONEncoder().encode(fx), as: UTF8.self)
        XCTAssertTrue(out.contains("\"enabled\":false"), "無効化したスロットも指定として残る: \(out)")
        // 無効な既存プロジェクト(vst3 が壊れた型)でも落ちず、値は extra に残る
        let broken = try JSONDecoder().decode(AudioFx.self, from: Data(#"{"vst3":42}"#.utf8))
        XCTAssertNil(broken.vst3)
        XCTAssertEqual(broken.extra["vst3"], .number(42))
    }

    func testClipWithVST3SlotRoundTrips() throws {
        var c = Clip(); c.type = .audio; c.src = "/tmp/a.wav"; c.duration = 2
        c.audioFx = AudioFx(vst3: [AudioFx.VST3Slot(bundleID: "com.example.testverb", name: "TestVerb")])
        let back = try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(back.audioFx, c.audioFx)
        XCTAssertEqual(back.audioFx?.vst3Slots.first?.audioEffectID, "vst3.com.example.testverb")
    }

    // MARK: 編集

    func audioClip() -> Clip { var c = Clip(); c.type = .audio; c.src = "/tmp/a.wav"; c.duration = 2; return c }

    func testVST3EditingAddRemoveToggle() {
        var c = audioClip()
        XCTAssertTrue(AudioFxEditing.addVST3Slot(&c, bundleID: "com.example.testverb", name: "TestVerb"))
        XCTAssertFalse(AudioFxEditing.addVST3Slot(&c, bundleID: "COM.EXAMPLE.TESTVERB"), "同じプラグインは重ねない")
        XCTAssertFalse(AudioFxEditing.addVST3Slot(&c, bundleID: "  "), "空の ID は入れない")
        XCTAssertEqual(c.audioFx?.vst3Slots.count, 1)
        XCTAssertTrue(AudioFxEditing.setVST3SlotEnabled(&c, at: 0, enabled: false))
        XCTAssertFalse(AudioFxEditing.setVST3SlotEnabled(&c, at: 0, enabled: false), "同じ状態は変化なし")
        XCTAssertFalse(AudioFxEditing.setVST3SlotEnabled(&c, at: 5, enabled: true), "範囲外は変化なし")
        XCTAssertTrue(AudioFxEditing.removeVST3Slot(&c, at: 0))
        XCTAssertNil(c.audioFx, "全部外れたら audioFx ごと無くなる")
        XCTAssertFalse(AudioFxEditing.removeVST3Slot(&c, at: 0))
        // 音声を受けられないクリップ(文字)には付けない
        var t = Clip(); t.type = .text; t.duration = 1
        XCTAssertFalse(AudioFxEditing.addVST3Slot(&t, bundleID: "com.example.testverb"))
        XCTAssertNil(t.audioFx)
    }

    // MARK: ミックス経由のバイト一致(音が変わらないことの保証)

    func testMixdownWithVST3SlotIsByteIdentical() throws {
        let srcURL = tmp.appendingPathComponent("tone.wav")
        try AudioFixture.writeSine(srcURL, sampleRate: 48000, channels: 2, frequency: 440, segments: [(2, 0.3)])
        func clip(_ fx: AudioFx?) -> Clip {
            var c = Clip(); c.type = .audio; c.src = srcURL.path; c.start = 0; c.duration = 2; c.srcDuration = 2; c.volume = 1
            c.audioFx = fx
            return c
        }
        func mix(_ c: Clip, _ name: String) throws -> (l: [Float], r: [Float]) {
            var p = Project(); var t = Track(name: "L"); t.clips = [c]; p.tracks = [t]
            let url = tmp.appendingPathComponent(name)
            try AudioMixer.mixdown(project: p, assets: RenderAssets(), to: url)
            let f = try AVAudioFile(forReading: url)
            let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
            try f.read(into: buf)
            let n = Int(buf.frameLength)
            return (Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: n)),
                    Array(UnsafeBufferPointer(start: buf.floatChannelData![1], count: n)))
        }
        let dry = try mix(clip(nil), "dry.caf")
        let withSlot = try mix(clip(AudioFx(vst3: [AudioFx.VST3Slot(bundleID: "com.example.testverb", name: "TestVerb")])), "slot.caf")
        XCTAssertEqual(withSlot.l, dry.l, "VST3 スロット(有効)でも従来とバイト一致")
        XCTAssertEqual(withSlot.r, dry.r)
        let disabled = try mix(clip(AudioFx(vst3: [AudioFx.VST3Slot(bundleID: "com.example.testverb", enabled: false)])), "off.caf")
        XCTAssertEqual(disabled.l, dry.l, "VST3 スロット(無効)でも従来とバイト一致")
    }
}
