import XCTest
import AVFoundation
@testable import MovieCutCore

/// VST3 再生/書き出し配線の検証(ラウンド3)。
/// 実プラグイン・実ブリッジ・キーチェーンには触らず、ブリッジバックエンドのフェイク
/// (ゲイン 0.5 倍)で「各経路にプロバイダを渡すと音が実際に変わり、渡さなければ従来と一致する」
/// ことを経路ごとに固定する。ミックス単体の検証は `VST3HostTests` 側にある。
final class VST3WiringTests: XCTestCase {

    // MARK: フェイクバックエンド(VST3HostTests の流儀: パラメータ 0 = ゲイン)

    final class FakeGainBackend: VST3BridgeBackend {
        var gain: Double = 1
        func handshake() -> (status: VST3BridgeStatus, version: Int32?) { (.ok, VST3Bridge.protocolVersion) }
        func openBundle(path: String) -> VST3BridgeStatus { .ok }
        func classInfos() -> (status: VST3BridgeStatus, infos: [VST3BridgeClassInfo]) {
            (.ok, [VST3BridgeClassInfo(category: "Audio Module Class", name: "FakeGain", cidHex: "00")])
        }
        func createProcessor(cid: String?) -> VST3BridgeStatus { .ok }
        func setupProcessing(_ setup: VST3ProcessSetup, layout: VST3BusLayout) -> VST3BridgeStatus { .ok }
        func setActive(_ active: Bool) -> VST3BridgeStatus { .ok }
        func processBlock(inputLeft: UnsafePointer<Float>, inputRight: UnsafePointer<Float>,
                          outputLeft: UnsafeMutablePointer<Float>, outputRight: UnsafeMutablePointer<Float>,
                          frames: Int, changes: [VST3ParameterChangePoint]) -> (status: VST3BridgeStatus, latency: Int?) {
            let sorted = changes.filter { $0.parameterID == 0 }.sorted { $0.sampleOffset < $1.sampleOffset }
            var next = 0
            for i in 0..<frames {
                while next < sorted.count, sorted[next].sampleOffset <= i { gain = sorted[next].normalizedValue; next += 1 }
                outputLeft[i] = inputLeft[i] * Float(gain)
                outputRight[i] = inputRight[i] * Float(gain)
            }
            return (.ok, 0)
        }
        func parameterInfos() -> (status: VST3BridgeStatus, infos: [VST3ParameterDescriptor]) {
            (.ok, [VST3ParameterDescriptor(id: 0, title: "Gain", stepCount: 0, defaultNormalizedValue: 1, flags: [.canAutomate])])
        }
        func getParameterNormalized(id: UInt32) -> (status: VST3BridgeStatus, value: Double?) { (.ok, id == 0 ? gain : nil) }
        func setParameterNormalized(id: UInt32, value: Double) -> VST3BridgeStatus { if id == 0 { gain = value }; return .ok }
        func latencyAndTail() -> (latency: Int, tail: Int)? { (0, 0) }
        func getState() -> (status: VST3BridgeStatus, data: Data?) { (.ok, nil) }
        func setState(_ data: Data) -> VST3BridgeStatus { .ok }
        func dispose() {}
    }

    private var tmp: URL!
    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vst3wiring-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private var fakeInfo: VST3BundleInfo {
        VST3BundleInfo(bundleURL: tmp.appendingPathComponent("FakeGain.vst3"),
                       name: "FakeGain", bundleIdentifier: "com.example.fakegain", architectures: ["arm64"])
    }
    private var gainProvider: VST3EffectProvider {
        VST3EffectProvider(plugins: [fakeInfo], backendFactory: { _ in FakeGainBackend() })
    }

    /// 振幅 0.3 の正弦波クリップに VST3 スロット(ゲイン 0.5)を付けた小さなプロジェクト。
    private func project() throws -> Project {
        let src = tmp.appendingPathComponent("tone.wav")
        try AudioFixture.writeSine(src, sampleRate: 48000, channels: 2, frequency: 440, segments: [(1, 0.3)])
        var c = Clip(); c.type = .audio; c.src = src.path; c.start = 0; c.duration = 1; c.srcDuration = 1; c.volume = 1
        c.audioFx = AudioFx(vst3: [AudioFx.VST3Slot(bundleID: "com.example.fakegain", name: "FakeGain", params: ["0": 0.5])])
        var p = Project(); p.width = 320; p.height = 180; p.fps = 10
        var t = Track(name: "L"); t.clips = [c]; p.tracks = [t]
        return p
    }

    /// 書き出したファイル(動画コンテナ含む)の音声ピークを AVAssetReader で測る。
    private func containerAudioPeak(_ url: URL) throws -> Float {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first else { return 0 }
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
        ])
        reader.add(out)
        guard reader.startReading() else { throw CocoaError(.fileReadUnknown) }
        var peak: Float = 0
        while let sb = out.copyNextSampleBuffer(), let bb = CMSampleBufferGetDataBuffer(sb) {
            let n = CMBlockBufferGetDataLength(bb) / MemoryLayout<Float>.size
            var buf = [Float](repeating: 0, count: n)
            _ = buf.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: n * MemoryLayout<Float>.size, destination: $0.baseAddress!) }
            for v in buf { peak = max(peak, abs(v)) }
        }
        return peak
    }

    // MARK: 書き出し経路(ExportJob → Exporter / AudioExporter)

    func testExportJobAudioOnlyAppliesVST3() async throws {
        let p = try project()
        let dry = tmp.appendingPathComponent("dry.m4a")
        try await ExportJob.run(project: p, preset: .audio, to: dry)
        let wet = tmp.appendingPathComponent("wet.m4a")
        try await ExportJob.run(project: p, preset: .audio, to: wet, vst3Provider: gainProvider)
        let dryPeak = try AudioFixture.peak(dry, from: 0.05, to: 0.95)
        let wetPeak = try AudioFixture.peak(wet, from: 0.05, to: 0.95)
        XCTAssertEqual(dryPeak, 0.3, accuracy: 0.04, "プロバイダ無しではスロットがあっても原音(AAC の誤差込み)")
        XCTAssertEqual(wetPeak, 0.15, accuracy: 0.04, "音声のみ書き出しでもゲイン 0.5 が効く")
    }

    func testExporterVideoAppliesVST3() async throws {
        let p = try project()
        let dry = tmp.appendingPathComponent("dry.mp4")
        try await Exporter(project: p, assets: RenderAssets()).export(to: dry)
        let wet = tmp.appendingPathComponent("wet.mp4")
        try await Exporter(project: p, assets: RenderAssets(), vst3Provider: gainProvider).export(to: wet)
        XCTAssertEqual(try containerAudioPeak(dry), 0.3, accuracy: 0.04, "プロバイダ無しの動画書き出しは原音")
        XCTAssertEqual(try containerAudioPeak(wet), 0.15, accuracy: 0.04, "動画書き出しの音声にもゲイン 0.5 が効く")
    }

    func testPngWavExporterAppliesVST3() async throws {
        let p = try project()
        let dryDir = tmp.appendingPathComponent("dryseq"); let wetDir = tmp.appendingPathComponent("wetseq")
        let dry = try await PngWavExporter.export(project: p, to: dryDir)
        let wet = try await PngWavExporter.export(project: p, to: wetDir, vst3Provider: gainProvider)
        XCTAssertEqual(try AudioFixture.peak(dry.wavURL, from: 0.05, to: 0.95), 0.3, accuracy: 0.02)
        XCTAssertEqual(try AudioFixture.peak(wet.wavURL, from: 0.05, to: 0.95), 0.15, accuracy: 0.02, "連番PNG+WAV の WAV にも効く")
    }

    // MARK: 測定経路(Loudness は書き出しと同じミックスを測る)

    func testLoudnessMeasureReflectsVST3() throws {
        let p = try project()
        let dry = try XCTUnwrap(try LoudnessAnalysis.measure(project: p))
        let wet = try XCTUnwrap(try LoudnessAnalysis.measure(project: p, vst3Provider: gainProvider))
        XCTAssertEqual(wet.integrated, dry.integrated - 6.02, accuracy: 0.6, "ゲイン 0.5 倍 ≒ −6 dB が測定にも出る")
        XCTAssertEqual(wet.duration, dry.duration, accuracy: 0.01)
    }

    // MARK: 試聴経路(AudioAudition)

    func testAuditionSnippetAppliesVST3() throws {
        let p = try project()
        let clipId = try XCTUnwrap(p.tracks.first?.clips.first?.id)
        let dry = tmp.appendingPathComponent("dry.caf"); let wet = tmp.appendingPathComponent("wet.caf")
        XCTAssertNotNil(try AudioAudition.renderSnippet(project: p, clipId: clipId, at: 0, to: dry))
        XCTAssertNotNil(try AudioAudition.renderSnippet(project: p, clipId: clipId, at: 0, to: wet, vst3Provider: gainProvider))
        XCTAssertEqual(try AudioFixture.peak(dry, from: 0.02, to: 0.45), 0.3, accuracy: 0.02)
        XCTAssertEqual(try AudioFixture.peak(wet, from: 0.02, to: 0.45), 0.15, accuracy: 0.02, "試聴でもそのクリップの VST3 が効く")
    }

    // MARK: RenderAssets の合成音声解析(ビジュアライザ等)

    func testRenderAssetsComputeMixAppliesVST3() throws {
        let p = try project()
        let dryAssets = RenderAssets()
        let dry = try XCTUnwrap(RenderAssets.computeMix(p, assets: dryAssets, wantMono: false))
        let wetAssets = RenderAssets()
        wetAssets.setVST3Provider(gainProvider)
        let wet = try XCTUnwrap(RenderAssets.computeMix(p, assets: wetAssets, wantMono: false))
        let dryMax = dry.env.max() ?? 0, wetMax = wet.env.max() ?? 0
        XCTAssertGreaterThan(dryMax, 0.1)
        XCTAssertEqual(wetMax, dryMax * 0.5, accuracy: 0.02, "解析用のミックスも書き出しと同じ音になる")
    }

    /// 回帰: `mixEnvelope` / `vizEnvelope` はインスタンスの `lock` を握ったまま `computeMix` を呼ぶ。
    /// プロバイダの getter が同じ `lock` を取ると自己デッドロックし、ビジュアライザ描画が固まる
    /// (KitchenSink の描画テストが実際に止まった)。lock 越しでもエンベロープが返り、
    /// プロバイダの効果(ゲイン 0.5)が反映されることを固定する。
    func testMixEnvelopeThroughLockAppliesVST3WithoutDeadlock() throws {
        let p = try project()
        let dryAssets = RenderAssets()
        let dry = try XCTUnwrap(dryAssets.mixEnvelope(for: p))
        let wetAssets = RenderAssets()
        wetAssets.setVST3Provider(gainProvider)
        let wet = try XCTUnwrap(wetAssets.mixEnvelope(for: p))
        let dryMax = dry.max() ?? 0, wetMax = wet.max() ?? 0
        XCTAssertGreaterThan(dryMax, 0.1)
        XCTAssertEqual(wetMax, dryMax * 0.5, accuracy: 0.02, "lock 越しのミックスにも VST3 が効く")
        // vizEnvelope の source 指定分岐(もう 1 つの lock 保持側の呼び出し)も同じく返ること。
        let clipID = try XCTUnwrap(p.allClips.first?.id)
        let viz = try XCTUnwrap(wetAssets.vizEnvelope(for: p, source: clipID))
        XCTAssertEqual(viz.max() ?? 0, wetMax, accuracy: 0.02)
    }

    // MARK: 生成元の一本化

    func testStandardProviderIsBuiltFromStandardScan() {
        // 生成経路は VST3EffectProvider.standard() の 1 本だけ(スキャン結果からの構築と一致する)。
        let standard = VST3EffectProvider.standard()
        let fromScan = VST3EffectProvider(scanResult: VST3Scanner.scanStandard())
        XCTAssertEqual(standard.audioEffectDescriptors.map { $0.id },
                       fromScan.audioEffectDescriptors.map { $0.id })
    }
}
