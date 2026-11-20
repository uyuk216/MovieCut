import XCTest
import AVFoundation
@testable import MovieCutCore

/// VST3 ホスト本体(W6-1)の検証。実プラグインは使わず、ブリッジバックエンドの
/// フェイク(ゲイン処理)で「接続手順・バイパス不変条件・チェーン接続・ミックス経由」を固定する。
/// 実プラグイン(MovieCutGain フィクスチャ)+実ブリッジでの検証は
/// `Bridges/MovieCutVST3Host/Tests/smoke_test.py`(VM で実行済み)と Mac 実機手順に委ねる。
final class VST3HostTests: XCTestCase {

    // MARK: フェイクバックエンド(ゲイン 1 個のプラグインのつもり)

    final class FakeBackend: VST3BridgeBackend {
        var gain: Double = 1
        var failAt: String?
        var processFailAfterCalls: Int?
        private(set) var calls: [String] = []
        private(set) var blockSizes: [Int] = []
        private(set) var receivedState: Data?
        private(set) var disposed = false
        var storedState = Data([9, 8, 7])
        var latencyTail: (Int, Int)? = (128, 4800)
        let descriptors = [
            VST3ParameterDescriptor(id: 0, title: "Gain", stepCount: 0, defaultNormalizedValue: 0.75, flags: [.canAutomate]),
            VST3ParameterDescriptor(id: 1, title: "Bypass", stepCount: 1, defaultNormalizedValue: 0, flags: [.canAutomate, .isBypass]),
            VST3ParameterDescriptor(id: 2, title: "VuPPM", stepCount: 0, defaultNormalizedValue: 0, flags: [.isReadOnly]),
        ]
        private var processCount = 0

        func handshake() -> (status: VST3BridgeStatus, version: Int32?) { (.ok, VST3Bridge.protocolVersion) }
        func openBundle(path: String) -> VST3BridgeStatus { calls.append("open"); return failAt == "open" ? .notFound : .ok }
        func classInfos() -> (status: VST3BridgeStatus, infos: [VST3BridgeClassInfo]) {
            (.ok, [VST3BridgeClassInfo(category: "Audio Module Class", name: "FakeGain", cidHex: "00")])
        }
        func createProcessor(cid: String?) -> VST3BridgeStatus { calls.append("create"); return failAt == "create" ? .internalError : .ok }
        func setupProcessing(_ setup: VST3ProcessSetup, layout: VST3BusLayout) -> VST3BridgeStatus {
            calls.append("setup"); return failAt == "setup" ? .resultFalse : .ok
        }
        func setActive(_ active: Bool) -> VST3BridgeStatus { calls.append(active ? "active" : "inactive"); return failAt == "active" ? .internalError : .ok }
        func processBlock(inputLeft: UnsafePointer<Float>, inputRight: UnsafePointer<Float>,
                          outputLeft: UnsafeMutablePointer<Float>, outputRight: UnsafeMutablePointer<Float>,
                          frames: Int, changes: [VST3ParameterChangePoint]) -> (status: VST3BridgeStatus, latency: Int?) {
            processCount += 1
            blockSizes.append(frames)
            if let limit = processFailAfterCalls, processCount > limit { return (.internalError, nil) }
            if failAt == "process" { return (.internalError, nil) }
            let sorted = changes.filter { $0.parameterID == 0 }.sorted { $0.sampleOffset < $1.sampleOffset }
            var next = 0
            for i in 0..<frames {
                while next < sorted.count, sorted[next].sampleOffset <= i {
                    gain = sorted[next].normalizedValue; next += 1
                }
                outputLeft[i] = inputLeft[i] * Float(gain)
                outputRight[i] = inputRight[i] * Float(gain)
            }
            return (.ok, latencyTail?.0)
        }
        func parameterInfos() -> (status: VST3BridgeStatus, infos: [VST3ParameterDescriptor]) { (.ok, descriptors) }
        func getParameterNormalized(id: UInt32) -> (status: VST3BridgeStatus, value: Double?) { (.ok, id == 0 ? gain : nil) }
        func setParameterNormalized(id: UInt32, value: Double) -> VST3BridgeStatus {
            if id == 0 { gain = value }
            return .ok
        }
        func latencyAndTail() -> (latency: Int, tail: Int)? { latencyTail }
        func getState() -> (status: VST3BridgeStatus, data: Data?) { (.ok, storedState) }
        func setState(_ data: Data) -> VST3BridgeStatus { receivedState = data; return failAt == "state" ? .internalError : .ok }
        func dispose() { disposed = true; calls.append("dispose") }
    }

    private func makeHost(fake: FakeBackend, values: [String: Double] = ["0": 0.5], stateData: Data? = nil) -> VST3HostProcessor {
        VST3HostProcessor(effectID: "vst3.com.example.fakegain", backend: fake, bundlePath: "/tmp/FakeGain.vst3",
                          sampleRate: 48000, values: values, stateData: stateData)
    }

    private func run(_ p: any AudioEffectProcessing, _ input: [Float]) -> [Float] {
        var l = input, r = input
        l.withUnsafeMutableBufferPointer { lp in
            r.withUnsafeMutableBufferPointer { rp in p.process(left: lp.baseAddress!, right: rp.baseAddress!, frames: input.count) }
        }
        return l
    }

    // MARK: 接続と実処理

    func testHostProcessorProcessesWithFakeBackend() {
        let fake = FakeBackend()
        let host = makeHost(fake: fake)
        XCTAssertTrue(host.isReady, "接続手順が全部通れば ready")
        XCTAssertEqual(fake.calls, ["open", "create", "setup", "active"], "順序契約どおりの呼び出し順")
        XCTAssertEqual(host.parameterDescriptors.map { $0.id }, [0, 1, 2])
        XCTAssertEqual(host.latencyFrames, 128)
        XCTAssertEqual(host.tailFrames, 4800)
        let out = run(host, [1, -0.5, 0.25])
        XCTAssertEqual(out, [0.5, -0.25, 0.125], "初期パラメータ(ゲイン 0.5)が変化点として適用される")
        XCTAssertEqual(host.processedFrames, 3)
        XCTAssertEqual(host.bypassedFrames, 0)
    }

    func testHostProcessorBlockSplitting() {
        let fake = FakeBackend()
        let host = makeHost(fake: fake)
        _ = run(host, [Float](repeating: 1, count: 10000))
        XCTAssertEqual(fake.blockSizes, [4096, 4096, 1808], "setup の最大ブロック長で割る")
        XCTAssertEqual(host.processedFrames, 10000)
    }

    func testHostProcessorParamRoundTrip() {
        let fake = FakeBackend()
        let host = makeHost(fake: fake)
        XCTAssertTrue(host.setParameter(id: 0, normalizedValue: 0.25))
        XCTAssertEqual(fake.gain, 0.25, "バックエンドへ即時設定される")
        let out = run(host, [1])
        XCTAssertEqual(out, [0.25], "次ブロックの変化点としても適用される")
        // 範囲外は整形される(記述の規則)
        XCTAssertTrue(host.setParameter(id: 0, normalizedValue: 1.7))
        XCTAssertEqual(fake.gain, 1)
    }

    func testHostProcessorStateRestoreAndCapture() {
        let fake = FakeBackend()
        let host = makeHost(fake: fake, stateData: Data([1, 2, 3]))
        XCTAssertTrue(host.isReady)
        XCTAssertEqual(fake.receivedState, Data([1, 2, 3]), "生成時に状態が復元される")
        XCTAssertFalse(host.stateRestoreFailed)
        XCTAssertEqual(host.captureState(), Data([9, 8, 7]))

        let failing = FakeBackend(); failing.failAt = "state"
        let host2 = makeHost(fake: failing, stateData: Data([1]))
        XCTAssertTrue(host2.isReady, "状態復元の失敗は致命にしない")
        XCTAssertTrue(host2.stateRestoreFailed)
    }

    func testHostProcessorResetReappliesInitialValues() {
        let fake = FakeBackend()
        let host = makeHost(fake: fake)
        _ = run(host, [1])
        fake.gain = 1  // 外部要因で変わったつもりにする
        host.reset()
        XCTAssertEqual(host.processedFrames, 0)
        XCTAssertEqual(run(host, [1]), [0.5], "リセットで初期パラメータが再び変化点になる")
    }

    // MARK: バイパス不変条件(安全境界)

    func testHostProcessorBypassesWhenOpenFails() {
        let fake = FakeBackend(); fake.failAt = "open"
        let host = makeHost(fake: fake)
        XCTAssertFalse(host.isReady)
        XCTAssertEqual(host.failureStatus, .notFound)
        let input: [Float] = [0.5, -0.25, 1, -1]
        XCTAssertEqual(run(host, input), input, "未ロード時はバイト単位で原音")
        XCTAssertEqual(host.bypassedFrames, 4)
        XCTAssertEqual(host.processedFrames, 0)
    }

    func testHostProcessorBypassesWithUnavailableBackend() {
        let host = VST3HostProcessor(effectID: "vst3.x", backend: UnavailableVST3BridgeBackend(),
                                     bundlePath: "/tmp/none.vst3", sampleRate: 48000, values: [:])
        XCTAssertFalse(host.isReady)
        XCTAssertEqual(host.failureStatus, .notImplemented)
        let input: [Float] = [0.1, 0.2]
        XCTAssertEqual(run(host, input), input)
    }

    func testHostProcessorProcessFailureSwitchesToBypass() {
        let fake = FakeBackend(); fake.processFailAfterCalls = 1
        let host = makeHost(fake: fake)
        XCTAssertEqual(run(host, [1, 1]), [0.5, 0.5], "1 ブロック目は処理される")
        let input: [Float] = [1, 1]
        XCTAssertEqual(run(host, input), input, "失敗したブロックは入力へ戻さず、以降バイパス")
        XCTAssertFalse(host.isReady)
        XCTAssertEqual(host.failureStatus, .internalError)
        XCTAssertEqual(run(host, input), input, "恒常バイパスのまま")
    }

    // MARK: プロバイダ経由

    func testProviderWithFakeBackendProcessesAndFallsBackToBypass() {
        let info = VST3BundleInfo(bundleURL: URL(fileURLWithPath: "/tmp/FakeGain.vst3"),
                                  name: "FakeGain", bundleIdentifier: "com.example.fakegain",
                                  architectures: ["arm64"])
        let fake = FakeBackend()
        let provider = VST3EffectProvider(plugins: [info], backendFactory: { _ in fake })
        let proc = provider.makeProcessor(effectID: info.audioEffectID, sampleRate: 48000, values: ["0": 0.5])
        let host = proc as? VST3HostProcessor
        XCTAssertNotNil(host)
        if let host { XCTAssertEqual(run(host, [1]), [0.5]) }

        let failing = FakeBackend(); failing.failAt = "create"
        let provider2 = VST3EffectProvider(plugins: [info], backendFactory: { _ in failing })
        let proc2 = provider2.makeProcessor(effectID: info.audioEffectID, sampleRate: 48000, values: [:])
        XCTAssertTrue(proc2 is BypassAudioEffectProcessor, "作れなければバイパス処理器を返す(nil で経路を止めない)")
    }

    // MARK: チェーン接続(拡張の後・リミッターの前)

    func testChainAppliesVST3BeforeLimiter() {
        // 「0.5 倍 + リミッター天井 -1dB」で検証する: 入力 1.0 → VST3 で 0.5 → リミッターは素通し。
        let fake2 = FakeBackend()
        let host2 = makeHost(fake: fake2)  // ゲイン 0.5
        let fx = AudioFx(limiter: -1)
        let chain = AudioFxChain(fx, sr: 48000, vst3Processors: [host2])
        var l = [Float](repeating: 1, count: 512), r = [Float](repeating: 1, count: 512)
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in chain.process(lp.baseAddress!, rp.baseAddress!, 512) } }
        XCTAssertEqual(l.last!, 0.5, accuracy: 1e-6, "VST3(0.5 倍)がチェーン内で効く")

        // 順序: ゲイン 2 倍相当は setParameter の範囲外なので、入力 1.8 × ゲイン 0.5 = 0.9 が
        // リミッター天井(約 0.891)で抑えられることで「VST3 → リミッター」の順を確認する
        let fake3 = FakeBackend()
        let host3 = makeHost(fake: fake3)
        let chain3 = AudioFxChain(fx, sr: 48000, vst3Processors: [host3])
        var l3 = [Float](repeating: 1.8, count: 4800), r3 = [Float](repeating: 1.8, count: 4800)
        l3.withUnsafeMutableBufferPointer { lp in r3.withUnsafeMutableBufferPointer { rp in chain3.process(lp.baseAddress!, rp.baseAddress!, 4800) } }
        XCTAssertLessThanOrEqual(l3.last!, 0.9, "リミッターが VST3 の後段で天井を守る: \(l3.last!)")
        XCTAssertGreaterThan(l3.last!, 0.8)
    }

    func testChainWithoutVST3ProcessorsIsUnchanged() {
        let fx = AudioFx(limiter: -1)
        let plain = AudioFxChain(fx, sr: 48000)
        XCTAssertTrue(plain.vst3Processors.isEmpty)
        var l: [Float] = [0.5, -0.5], r: [Float] = [0.5, -0.5]
        let l0 = l
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in plain.process(lp.baseAddress!, rp.baseAddress!, 2) } }
        XCTAssertEqual(l, l0, "天井以下の音はリミッターでも変わらない(従来どおり)")
    }

    // MARK: ミックス経由

    func testMixdownWithFakeProviderAppliesGain() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vst3host-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let srcURL = tmp.appendingPathComponent("tone.wav")
        try AudioFixture.writeSine(srcURL, sampleRate: 48000, channels: 2, frequency: 440, segments: [(2, 0.3)])
        func clip() -> Clip {
            var c = Clip(); c.type = .audio; c.src = srcURL.path; c.start = 0; c.duration = 2; c.srcDuration = 2; c.volume = 1
            c.audioFx = AudioFx(vst3: [AudioFx.VST3Slot(bundleID: "com.example.fakegain", name: "FakeGain", params: ["0": 0.5])])
            return c
        }
        func mix(provider: (any AudioEffectProviding)?, _ name: String) throws -> [Float] {
            var p = Project(); var t = Track(name: "L"); t.clips = [clip()]; p.tracks = [t]
            let url = tmp.appendingPathComponent(name)
            try AudioMixer.mixdown(project: p, assets: RenderAssets(), to: url, vst3Provider: provider)
            let f = try AVAudioFile(forReading: url)
            let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
            try f.read(into: buf)
            return Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
        }
        let dry = try mix(provider: nil, "dry.caf")
        let info = VST3BundleInfo(bundleURL: tmp.appendingPathComponent("FakeGain.vst3"),
                                  name: "FakeGain", bundleIdentifier: "com.example.fakegain", architectures: ["arm64"])
        let provider = VST3EffectProvider(plugins: [info], backendFactory: { _ in FakeBackend() })
        let wet = try mix(provider: provider, "wet.caf")
        XCTAssertEqual(wet.count, dry.count)
        for (w, d) in zip(wet, dry) {
            XCTAssertEqual(w, d * 0.5, accuracy: 1e-4, "プロバイダ経由でゲイン 0.5 がミックスに効く")
        }
        // プロバイダが無い従来経路は、VST3 スロットがあってもバイト一致(既存テストと同条件を再確認)
        let dry2 = try mix(provider: nil, "dry2.caf")
        XCTAssertEqual(dry2, dry)
    }

    // MARK: ネイティブブリッジの探索

    func testCandidatePathsOrder() {
        let paths = VST3BridgeRuntime.candidatePaths(environment: [VST3BridgeRuntime.environmentKey: "/custom/bridge.dylib"],
                                                     frameworksPath: "/App/Contents/Frameworks",
                                                     executableDirectory: "/App/Contents/MacOS")
        XCTAssertEqual(paths.first, "/custom/bridge.dylib", "環境変数の明示指定が最優先")
        XCTAssertEqual(paths[1], "/App/Contents/Frameworks/" + VST3BridgeRuntime.libraryFileName)
        XCTAssertEqual(paths.last, "/App/Contents/MacOS/" + VST3BridgeRuntime.libraryFileName, "最後は実行ファイルの隣")
        XCTAssertFalse(paths.contains(VST3BridgeRuntime.libraryFileName), "名前だけの候補(dlopen 標準探索)は入れない")
        let noEnv = VST3BridgeRuntime.candidatePaths(environment: [:], frameworksPath: nil, executableDirectory: nil)
        XCTAssertFalse(noEnv.contains("/custom/bridge.dylib"))
    }

    func testNativeBackendMatchesRuntimeAvailability() {
        // テスト環境にブリッジが無いのが通常。その場合は backend は作れず、到達状態も検出のみ。
        // ブリッジを置いた環境では両方が成り立つことだけを確認する(環境依存の断定はしない)。
        XCTAssertEqual(VST3NativeBridgeBackend() != nil, VST3BridgeRuntime.isAvailable)
        XCTAssertEqual(VST3HostAvailability.current.canProcessAudio, VST3BridgeRuntime.isAvailable)
    }

    func testCABILayoutConstants() {
        // C++ 側 static_assert と対になる値。変えたら両方変える。
        XCTAssertEqual(VST3CABI.setupSize, 32)
        XCTAssertEqual(VST3CABI.setupSampleRateOffset, 8)
        XCTAssertEqual(VST3CABI.parameterInfoSize, 56)
        XCTAssertEqual(VST3CABI.parameterInfoDefaultOffset, 40)
        XCTAssertEqual(VST3CABI.parameterChangeSize, 16)
        XCTAssertEqual(VST3CABI.processRequestSize, 48)
        XCTAssertEqual(VST3CABI.processRequestLatencyOffset, 40)
        XCTAssertEqual(VST3CABI.classInfoSize, 72)
        XCTAssertEqual(VST3CABI.classInfoCIDHexOffset, 32)
        XCTAssertEqual(VST3CABI.speakerValue(.stereo), 2)
        XCTAssertEqual(VST3CABI.speakerValue(.surround51), 6)
        XCTAssertEqual(VST3CABI.processingModeValue(.offline), 2)
    }

    // MARK: 変化点の整形

    func testChangePointsSanitization() {
        let stepped = VST3ParameterDescriptor(id: 0, title: "Gain", stepCount: 3, defaultNormalizedValue: 0)
        let readOnly = VST3ParameterDescriptor(id: 2, title: "Vu", flags: [.isReadOnly])
        let points = VST3HostProcessor.changePoints(from: ["0": 0.4, "2": 0.5, "9": 0.5], descriptors: [stepped, readOnly])
        XCTAssertEqual(points.count, 1, "読専と未知は落とす")
        XCTAssertEqual(points.first?.normalizedValue ?? -1, 1.0 / 3.0, accuracy: 1e-12, "離散段へスナップ")
        // 記述が無いときは ID として解釈できるキーだけを範囲丸めして通す
        let bare = VST3HostProcessor.changePoints(from: ["0": 1.7, "x": 0.5], descriptors: [])
        XCTAssertEqual(bare.map { $0.parameterID }, [0])
        XCTAssertEqual(bare.first?.normalizedValue, 1)
    }

    // MARK: スロット編集(パラメータ/状態)

    func audioClip() -> Clip { var c = Clip(); c.type = .audio; c.src = "/tmp/a.wav"; c.duration = 2; return c }

    func testSlotParamEditing() {
        var c = audioClip()
        XCTAssertTrue(AudioFxEditing.addVST3Slot(&c, bundleID: "com.example.fakegain", name: "FakeGain"))
        XCTAssertTrue(AudioFxEditing.setVST3SlotParam(&c, at: 0, key: "0", value: 0.5))
        XCTAssertFalse(AudioFxEditing.setVST3SlotParam(&c, at: 0, key: "0", value: 0.5), "同じ値は変化なし")
        XCTAssertTrue(AudioFxEditing.setVST3SlotParam(&c, at: 0, key: "0", value: 1.7))
        XCTAssertEqual(c.audioFx?.vst3Slots[0].params?["0"], 1, "正規化範囲へ丸める")
        XCTAssertFalse(AudioFxEditing.setVST3SlotParam(&c, at: 0, key: "0", value: .nan), "有限でない値は受けない")
        XCTAssertFalse(AudioFxEditing.setVST3SlotParam(&c, at: 0, key: " ", value: 0.5))
        XCTAssertFalse(AudioFxEditing.setVST3SlotParam(&c, at: 3, key: "0", value: 0.5), "範囲外")
        XCTAssertTrue(AudioFxEditing.removeVST3SlotParam(&c, at: 0, key: "0"))
        XCTAssertNil(c.audioFx?.vst3Slots[0].params, "控えが空になったら params ごと無くなる")
        XCTAssertFalse(AudioFxEditing.removeVST3SlotParam(&c, at: 0, key: "0"))
    }

    func testSlotStateRoundTripAndEncoding() throws {
        let data = Data([0, 1, 2, 250])
        var slot = AudioFx.VST3Slot(bundleID: "com.example.fakegain", name: "FakeGain")
        XCTAssertNil(slot.state)
        let plainJSON = String(decoding: try JSONEncoder().encode(AudioFx(vst3: [slot])), as: UTF8.self)
        XCTAssertFalse(plainJSON.contains("\"state\""), "状態が無いときは書かない(従来と一致)")

        var c = audioClip()
        XCTAssertTrue(AudioFxEditing.addVST3Slot(&c, bundleID: "com.example.fakegain", name: "FakeGain"))
        XCTAssertTrue(AudioFxEditing.setVST3SlotState(&c, at: 0, stateData: data))
        XCTAssertFalse(AudioFxEditing.setVST3SlotState(&c, at: 0, stateData: data), "同じ状態は変化なし")
        slot = try XCTUnwrap(c.audioFx?.vst3Slots[0])
        XCTAssertEqual(slot.stateData, data)
        let encoded = try JSONEncoder().encode(c.audioFx!)
        let back = try JSONDecoder().decode(AudioFx.self, from: encoded)
        XCTAssertEqual(back, c.audioFx)
        XCTAssertEqual(back.vst3Slots[0].stateData, data)
        XCTAssertTrue(AudioFxEditing.setVST3SlotState(&c, at: 0, stateData: nil), "消去もできる")
        XCTAssertNil(c.audioFx?.vst3Slots[0].state)
        // 壊れた Base64 は保持するが stateData は nil(読みで落とさない)
        let broken = try JSONDecoder().decode(AudioFx.self, from: Data(#"{"vst3":[{"bundleId":"x","state":"!!!"}]}"#.utf8))
        XCTAssertEqual(broken.vst3Slots[0].state, "!!!")
        XCTAssertNil(broken.vst3Slots[0].stateData)
    }

    func testVST3CacheTokenDeterministic() {
        var fx = AudioFx()
        XCTAssertEqual(fx.vst3CacheToken, "")
        fx = AudioFx(vst3: [AudioFx.VST3Slot(bundleID: "com.example.fakegain", params: ["1": 0.5, "0": 0.25])])
        XCTAssertEqual(fx.vst3CacheToken, "vst3=com.example.fakegain(0=0.25,1=0.5)", "キーはソートして決定的に")
        XCTAssertEqual(fx.cacheToken, "", "従来の cacheToken には含めない(音が変わらない経路の互換)")
        fx.vst3?[0].enabled = false
        XCTAssertEqual(fx.vst3CacheToken, "", "無効なスロットは含めない")
    }
}
