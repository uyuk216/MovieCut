import XCTest
import AVFoundation
@testable import MovieCutCore

/// 書き出し時ラウドネス正規化(計画・適用)。合成信号の理論値と比べる(LoudnessTests と同じ流儀)。
/// 理論値: 振幅 0.1 の 1 kHz ステレオ同相 → 統合 ≈ −19.99 LUFS、トゥルーピーク ≈ −20 dBTP。
/// 目標 −14 LUFS なら要求ゲイン ≈ +5.99 dB(ピーク −20 + 5.99 = −14.0 なので上限 −1 dBTP には届かない)。
final class LoudnessNormalizationTests: XCTestCase {
    private func sine(hz: Double, amplitude: Double, seconds: Double) -> [Float] {
        let n = Int(seconds * 48_000)
        return (0..<n).map { i in Float(amplitude * sin(2 * Double.pi * hz * Double(i) / 48_000)) }
    }

    /// 決定的な疑似乱数(LCG)による一様ノイズ [-amplitude, amplitude]。毎回同じ列。
    private func noise(amplitude: Double, seconds: Double, seed: UInt64) -> [Float] {
        var state = seed
        return (0..<Int(seconds * 48_000)).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let u = Double(state >> 11) / Double(1 << 53)      // 0..<1
            return Float((u * 2 - 1) * amplitude)
        }
    }

    private func report(integrated: Double, truePeak: Double) -> LoudnessReport {
        LoudnessReport(integrated: integrated, shortTermMax: integrated, truePeakDb: truePeak, samplePeakDb: truePeak, duration: 10)
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("moviecut-loudnorm-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 48 kHz ステレオ Float32 の CAF を書く(AudioMixer の出力と同じ形式)。
    private func writeCAF(left: [Float], right: [Float], to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000.0, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let fmt = file.processingFormat
        var i = 0
        while i < left.count {
            let n = min(10_000, left.count - i)
            let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n))!
            buf.frameLength = AVAudioFrameCount(n)
            for k in 0..<n { buf.floatChannelData![0][k] = left[i + k]; buf.floatChannelData![1][k] = right[i + k] }
            try file.write(from: buf)
            i += n
        }
    }

    private func frameCount(_ url: URL) throws -> AVAudioFramePosition { try AVAudioFile(forReading: url).length }

    // MARK: 1. 計画

    func testPlanForStereoSineAtMinus20dBFSGivesAbout6dBBoost() throws {
        let x = sine(hz: 1000, amplitude: 0.1, seconds: 6)
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("in.caf")
        try writeCAF(left: x, right: x, to: url)
        let r = try LoudnessAnalysis.measureFile(url)
        let p = LoudnessNormalization.plan(report: r, settings: .youtube)
        XCTAssertEqual(r.integrated, -19.99, accuracy: 0.3)
        XCTAssertEqual(r.truePeakDb, -20.0, accuracy: 0.3)
        XCTAssertEqual(p.requestedGainDb, 5.99, accuracy: 0.3)
        XCTAssertEqual(p.appliedGainDb, p.requestedGainDb, accuracy: 1e-12)
        XCTAssertFalse(p.limitedByTruePeak)
        XCTAssertEqual(p.linearGain, pow(10, p.appliedGainDb / 20), accuracy: 1e-12)
        XCTAssertEqual(p.measured, r)
    }

    // MARK: 2. ピーク制限

    func testPlanLimitedByTruePeakCapsAtCeilingMinusPeak() {
        // 統合 −20、ピーク −3 dBTP。目標 −14 だと +6 dB 要るが、−3 + 6 = +3 > −1 なので ceiling − peak = +2 dB に抑える
        let p = LoudnessNormalization.plan(report: report(integrated: -20, truePeak: -3), settings: .youtube)
        XCTAssertEqual(p.requestedGainDb, 6, accuracy: 1e-12)
        XCTAssertEqual(p.appliedGainDb, 2, accuracy: 1e-12)
        XCTAssertTrue(p.limitedByTruePeak)
        XCTAssertEqual(p.linearGain, pow(10, 2.0 / 20), accuracy: 1e-12)
    }

    func testPlanLimitedByTruePeakCanTurnIntoAttenuation() {
        // 統合 −16(目標 −14 は +2 dB 増幅)だが、ピークが +1 dBTP: 増幅どころか ceiling − peak = −2 dB へ下げる
        let p = LoudnessNormalization.plan(report: report(integrated: -16, truePeak: 1), settings: .youtube)
        XCTAssertEqual(p.requestedGainDb, 2, accuracy: 1e-12)
        XCTAssertEqual(p.appliedGainDb, -2, accuracy: 1e-12)
        XCTAssertTrue(p.limitedByTruePeak)
    }

    func testPlanAttenuationTowardTargetAlsoRespectsCeiling() {
        // 統合 −8 → 目標 −14 へ −6 dB。ピーク +0 dBTP は −6 で −6 dBTP ≤ −1 なので制限なし
        let a = LoudnessNormalization.plan(report: report(integrated: -8, truePeak: 0), settings: .youtube)
        XCTAssertEqual(a.appliedGainDb, -6, accuracy: 1e-12)
        XCTAssertFalse(a.limitedByTruePeak)
        // 統合 −13、ピーク +4 dBTP: 目標へは −1 dB だが、上限へは −5 dB 要る → −5 dB
        let b = LoudnessNormalization.plan(report: report(integrated: -13, truePeak: 4), settings: .youtube)
        XCTAssertEqual(b.requestedGainDb, -1, accuracy: 1e-12)
        XCTAssertEqual(b.appliedGainDb, -5, accuracy: 1e-12)
        XCTAssertTrue(b.limitedByTruePeak)
    }

    // MARK: 3. 無音・無効

    func testPlanSilenceAndDisabledApplyZero() {
        let silent = LoudnessNormalization.plan(report: report(integrated: -.infinity, truePeak: -.infinity), settings: .youtube)
        XCTAssertEqual(silent.appliedGainDb, 0)
        XCTAssertEqual(silent.requestedGainDb, 0)
        XCTAssertEqual(silent.linearGain, 1)
        XCTAssertFalse(silent.limitedByTruePeak)
        XCTAssertTrue(silent.isNoOp)

        let off = LoudnessNormalization.plan(report: report(integrated: -20, truePeak: -20), settings: .disabled)
        XCTAssertEqual(off.appliedGainDb, 0)
        XCTAssertEqual(off.linearGain, 1)
        XCTAssertFalse(off.limitedByTruePeak)
        XCTAssertTrue(off.isNoOp)
    }

    func testPlanShortClipWithoutIntegratedAppliesOnlyTruePeakCeiling() {
        // 400 ms 未満は統合が −∞ でもピークは測れている。上限 −1 dBTP へ −3 dB 下げる。目標への増幅は定義できないので 0
        let p = LoudnessNormalization.plan(report: report(integrated: -.infinity, truePeak: 2.0), settings: .youtube)
        XCTAssertEqual(p.appliedGainDb, -3, accuracy: 1e-12)
        XCTAssertTrue(p.limitedByTruePeak)
        XCTAssertEqual(p.requestedGainDb, 0)
        XCTAssertEqual(p.linearGain, pow(10, -3.0 / 20), accuracy: 1e-12)
        XCTAssertFalse(p.isNoOp)
    }

    func testPlanShortClipQuietPeakIsNoOp() {
        // 統合は −∞ だがピークは上限内: 増幅はしない
        let p = LoudnessNormalization.plan(report: report(integrated: -.infinity, truePeak: -5.0), settings: .youtube)
        XCTAssertEqual(p.appliedGainDb, 0)
        XCTAssertFalse(p.limitedByTruePeak)
        XCTAssertTrue(p.isNoOp)
    }

    func testPlanTrueSilenceWithIntegratedMinusInfinityAppliesZero() {
        let p = LoudnessNormalization.plan(report: report(integrated: -.infinity, truePeak: -.infinity), settings: .youtube)
        XCTAssertEqual(p.appliedGainDb, 0)
        XCTAssertEqual(p.requestedGainDb, 0)
        XCTAssertFalse(p.limitedByTruePeak)
        XCTAssertTrue(p.isNoOp)
    }

    func testPlanDisabledWithIntegratedMinusInfinityAppliesZeroEvenIfPeakIsHigh() {
        let p = LoudnessNormalization.plan(report: report(integrated: -.infinity, truePeak: 2.0), settings: .disabled)
        XCTAssertEqual(p.appliedGainDb, 0)
        XCTAssertFalse(p.limitedByTruePeak)
        XCTAssertTrue(p.isNoOp)
    }

    func testSettingsDefaultsAndClamping() {
        XCTAssertFalse(LoudnessNormalizationSettings().enabled)
        XCTAssertEqual(LoudnessNormalizationSettings().targetLUFS, -14)
        XCTAssertEqual(LoudnessNormalizationSettings().truePeakCeilingDbTP, -1)
        XCTAssertEqual(LoudnessNormalizationSettings.disabled, LoudnessNormalizationSettings())
        XCTAssertTrue(LoudnessNormalizationSettings.youtube.enabled)
        XCTAssertEqual(LoudnessNormalizationSettings.clampedTarget(-50), -36)
        XCTAssertEqual(LoudnessNormalizationSettings.clampedTarget(0), -5)
        XCTAssertEqual(LoudnessNormalizationSettings.clampedTarget(-16), -16)
        XCTAssertEqual(LoudnessNormalizationSettings.clampedTarget(.nan), -14)
        XCTAssertEqual(LoudnessNormalizationSettings.clampedCeiling(-10), -6)
        XCTAssertEqual(LoudnessNormalizationSettings.clampedCeiling(3), 0)
        XCTAssertEqual(LoudnessNormalizationSettings(enabled: true, targetLUFS: -99, truePeakCeilingDbTP: 9).targetLUFS, -36)
        XCTAssertEqual(LoudnessNormalizationSettings(enabled: true, targetLUFS: -99, truePeakCeilingDbTP: 9).truePeakCeilingDbTP, 0)
    }

    // MARK: 4. 適用ファイル

    func testNormalizeSineFileReachesTargetWithinCeilingAndKeepsFrameCount() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let x = sine(hz: 1000, amplitude: 0.1, seconds: 5)
        let input = dir.appendingPathComponent("in.caf"), output = dir.appendingPathComponent("out.caf")
        try writeCAF(left: x, right: x, to: input)

        let result = try LoudnessNormalization.normalize(input: input, output: output, settings: .youtube)
        XCTAssertEqual(result.outputURL, output)
        let after = try LoudnessAnalysis.measureFile(output)
        print("[loudnorm sine] before=\(result.plan.measured.integrated) LUFS / \(result.plan.measured.truePeakDb) dBTP, requested=\(result.plan.requestedGainDb) applied=\(result.plan.appliedGainDb) dB, after=\(after.integrated) LUFS / \(after.truePeakDb) dBTP")
        XCTAssertEqual(after.integrated, -14, accuracy: 0.3)
        XCTAssertLessThanOrEqual(after.truePeakDb, -1.0 + 0.05)
        XCTAssertEqual(try frameCount(output), try frameCount(input), "フレーム数は完全一致")
        XCTAssertEqual(try frameCount(input), 5 * 48_000)
        XCTAssertEqual(result.plan.appliedGainDb, 5.99, accuracy: 0.3)
    }

    func testNormalizeShortLoudClipAppliesTruePeakCeilingWithoutIntegrated() throws {
        // 300 ms(< 400 ms)の 1 kHz 振幅 1.0 は統合が測れず −∞、ピークは 0 dBTP 付近。上限 −1 dBTP まで下げられる
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let x = sine(hz: 1000, amplitude: 1.0, seconds: 0.3)
        let input = dir.appendingPathComponent("in.caf"), output = dir.appendingPathComponent("out.caf")
        try writeCAF(left: x, right: x, to: input)
        let before = try LoudnessAnalysis.measureFile(input)
        XCTAssertFalse(before.integrated.isFinite, "400 ms 未満なので統合は −∞")
        XCTAssertGreaterThan(before.truePeakDb, -1.0)

        let result = try LoudnessNormalization.normalize(input: input, output: output, settings: .youtube)
        XCTAssertEqual(result.outputURL, output, "統合が −∞ でも減衰が必要なので適用ファイルができる")
        XCTAssertTrue(result.plan.limitedByTruePeak)
        XCTAssertLessThan(result.plan.appliedGainDb, 0)
        let after = try LoudnessAnalysis.measureFile(output)
        print("[loudnorm short] before=\(before.truePeakDb) dBTP, applied=\(result.plan.appliedGainDb) dB, after=\(after.truePeakDb) dBTP")
        XCTAssertLessThanOrEqual(after.truePeakDb, -1.0 + 0.05)
        XCTAssertEqual(try frameCount(output), try frameCount(input))
    }

    func testNormalizeLimitedFileStaysUnderCeiling() throws {
        // 高いピーク(スパイク)つきの静かな音: 目標へ上げるとピーク上限が先に効く
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        var x = sine(hz: 1000, amplitude: 0.05, seconds: 5)
        x[100_000] = 0.5
        let input = dir.appendingPathComponent("in.caf"), output = dir.appendingPathComponent("out.caf")
        try writeCAF(left: x, right: x, to: input)
        let result = try LoudnessNormalization.normalize(input: input, output: output, settings: .youtube)
        let after = try LoudnessAnalysis.measureFile(output)
        print("[loudnorm limited] requested=\(result.plan.requestedGainDb) applied=\(result.plan.appliedGainDb) limited=\(result.plan.limitedByTruePeak) after=\(after.integrated) LUFS / \(after.truePeakDb) dBTP")
        XCTAssertTrue(result.plan.limitedByTruePeak)
        XCTAssertLessThan(result.plan.appliedGainDb, result.plan.requestedGainDb)
        XCTAssertLessThanOrEqual(after.truePeakDb, -1.0 + 0.05)
        XCTAssertEqual(try frameCount(output), try frameCount(input))
    }

    func testApplyClampsToFullScale() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let x = sine(hz: 1000, amplitude: 0.5, seconds: 1)
        let input = dir.appendingPathComponent("in.caf"), output = dir.appendingPathComponent("out.caf")
        try writeCAF(left: x, right: x, to: input)
        try LoudnessNormalization.apply(linearGain: 10, input: input, output: output)   // +20 dB: 振幅 5 → [-1,1] に収める
        let r = try LoudnessAnalysis.measureFile(output)
        XCTAssertEqual(r.samplePeakDb, 0.0, accuracy: 1e-6)
        XCTAssertEqual(try frameCount(output), 48_000)
    }

    // MARK: 5. ノイズ

    func testNormalizeDeterministicNoiseConverges() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let l = noise(amplitude: 0.1, seconds: 8, seed: 12345), r = noise(amplitude: 0.1, seconds: 8, seed: 67890)
        let input = dir.appendingPathComponent("in.caf"), output = dir.appendingPathComponent("out.caf")
        try writeCAF(left: l, right: r, to: input)
        for target in [-14.0, -23.0] {
            let result = try LoudnessNormalization.normalize(input: input, output: output, settings: .enabled(targetLUFS: target))
            let after = try LoudnessAnalysis.measureFile(output)
            print("[loudnorm noise] target=\(target) before=\(result.plan.measured.integrated) LUFS / \(result.plan.measured.truePeakDb) dBTP, requested=\(result.plan.requestedGainDb) applied=\(result.plan.appliedGainDb) after=\(after.integrated) LUFS / \(after.truePeakDb) dBTP")
            XCTAssertEqual(after.integrated, target, accuracy: 0.5)
            XCTAssertLessThanOrEqual(after.truePeakDb, -1.0 + 0.05)
            XCTAssertEqual(try frameCount(output), try frameCount(input))
        }
    }

    // MARK: 6. 変更なし

    func testNoOpCreatesNoFileAndLeavesInputBytesUnchanged() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let x = sine(hz: 1000, amplitude: 0.1, seconds: 5)
        let input = dir.appendingPathComponent("in.caf"), output = dir.appendingPathComponent("out.caf")
        try writeCAF(left: x, right: x, to: input)
        let before = try Data(contentsOf: input)

        // 無効: 計測も変換もしない
        let off = try LoudnessNormalization.normalize(input: input, output: output, settings: .disabled)
        XCTAssertNil(off.outputURL)
        XCTAssertTrue(off.plan.isNoOp)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))

        // 既に目標と一致(目標 = 測った統合): ゲイン 0
        let measured = try LoudnessAnalysis.measureFile(input).integrated
        let same = try LoudnessNormalization.normalize(input: input, output: output, settings: .enabled(targetLUFS: measured))
        XCTAssertNil(same.outputURL)
        XCTAssertEqual(same.plan.appliedGainDb, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))

        XCTAssertEqual(try Data(contentsOf: input), before, "元ファイルのバイトは変わらない")
    }

    func testNoOpForSilentFile() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let z = [Float](repeating: 0, count: 48_000 * 2)
        let input = dir.appendingPathComponent("in.caf"), output = dir.appendingPathComponent("out.caf")
        try writeCAF(left: z, right: z, to: input)
        let result = try LoudnessNormalization.normalize(input: input, output: output, settings: .youtube)
        XCTAssertNil(result.outputURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testUnsupportedFormatThrowsJapaneseError() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("in.caf")
        // 44.1 kHz のファイル
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100.0, AVNumberOfChannelsKey: 2,
                                       AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true]
        let f = try AVAudioFile(forWriting: input, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: 4410)!
        b.frameLength = 4410
        try f.write(from: b)
        XCTAssertThrowsError(try LoudnessNormalization.normalize(input: input, output: dir.appendingPathComponent("o.caf"), settings: .youtube)) { e in
            XCTAssertTrue(e is LoudnessNormalizationError)
            XCTAssertTrue((e as? LocalizedError)?.errorDescription?.contains("ラウドネス正規化") ?? false)
        }
    }

    // MARK: - 7. Exporter 統合

    /// 2 秒のプロジェクト(文字 + トーンのボイス)。ExporterTests.twoSecondProject 相当。
    private func twoSecondToneProject(in dir: URL) throws -> Project {
        var p = Project.new()
        p.width = 640; p.height = 360; p.fps = 30; p.codec = "h264"
        var text = Clip(); text.type = .text; text.text = "テスト"; text.start = 0; text.duration = 2
        text.x = 0.5; text.y = 0.3; text.fontSize = 60
        p.tracks[4].clips.append(text)
        let wav = dir.appendingPathComponent("tone.wav")
        try ToneVoiceProvider.writeTone(to: wav, duration: 1.85, frequency: 330)
        var v = Clip(); v.type = .voice; v.start = 0; v.duration = 2; v.src = wav.path; v.text = "ぴー"
        v.charId = p.characters[0].id; v.volume = 1; v.subtitle = true; v.fontSize = 40
        p.tracks[0].clips.append(v)
        return p
    }

    /// 書き出した MP4 の音声トラックを 48 kHz ステレオ Float32 PCM に戻して測る。
    private func measureExportedAudio(_ url: URL) async throws -> LoudnessReport {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first, "音声トラックがない")
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
        ])
        reader.add(out)
        XCTAssertTrue(reader.startReading())
        let meter = LoudnessMeter()
        while let sb = out.copyNextSampleBuffer() {
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
            var len = 0
            var ptr: UnsafeMutablePointer<Int8>?
            XCTAssertEqual(CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &ptr), kCMBlockBufferNoErr)
            let frames = len / (2 * MemoryLayout<Float>.size)
            guard let base = ptr, frames > 0 else { continue }
            let f = UnsafeMutableRawPointer(base).bindMemory(to: Float.self, capacity: frames * 2)
            var l = [Float](repeating: 0, count: frames), r = [Float](repeating: 0, count: frames)
            for i in 0..<frames { l[i] = f[2 * i]; r[i] = f[2 * i + 1] }
            l.withUnsafeBufferPointer { lp in r.withUnsafeBufferPointer { rp in meter.add(lp.baseAddress!, rp.baseAddress!, frames) } }
        }
        XCTAssertEqual(reader.status, .completed)
        return meter.finish()
    }

    func testExporterIntegrationNormalizesToTarget() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = try twoSecondToneProject(in: dir)

        let offURL = dir.appendingPathComponent("off.mp4")
        let t0 = Date()
        try await Exporter(project: p, assets: RenderAssets()).export(to: offURL)
        let offSecs = Date().timeIntervalSince(t0)
        let off = try await measureExportedAudio(offURL)

        let onURL = dir.appendingPathComponent("on.mp4")
        let t1 = Date()
        try await Exporter(project: p, assets: RenderAssets(), loudness: .enabled(targetLUFS: -14)).export(to: onURL)
        let onSecs = Date().timeIntervalSince(t1)
        let on = try await measureExportedAudio(onURL)

        print("LOUDNORM-INTEGRATION off: \(off.integrated) LUFS / \(off.truePeakDb) dBTP (\(offSecs)s); on: \(on.integrated) LUFS / \(on.truePeakDb) dBTP (\(onSecs)s)")
        XCTAssertTrue(off.integrated.isFinite)
        XCTAssertEqual(on.integrated, -14, accuracy: 1.0)
        XCTAssertLessThanOrEqual(on.truePeakDb, -0.2)
        XCTAssertGreaterThan(FileManager.default.contents(atPath: offURL.path)?.count ?? 0, 0)
    }

    func testAudioExporterIntegrationNormalizesToTarget() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = try twoSecondToneProject(in: dir)
        let out = dir.appendingPathComponent("on.m4a")
        try await AudioExporter.export(project: p, to: out, loudness: .enabled(targetLUFS: -14))
        let on = try await measureExportedAudio(out)
        print("LOUDNORM-INTEGRATION m4a on: \(on.integrated) LUFS / \(on.truePeakDb) dBTP")
        XCTAssertEqual(on.integrated, -14, accuracy: 1.0)
        XCTAssertLessThanOrEqual(on.truePeakDb, -0.2)
    }
}
