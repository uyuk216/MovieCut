import XCTest
@testable import MovieCutCore

/// 音声スペクトログラム: 既知の信号(単音・2音・無音)でピーク周波数が正しく出ること、
/// 窓関数・ホップ・列数上限・尺の打ち切り、空データの安全な扱いを検証する。
final class SpectrogramTests: XCTestCase {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("spectrogram-tests-\(UUID().uuidString)")
    override func setUpWithError() throws { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func sine(_ f: Double, seconds: Double, amp: Float = 0.5, sr: Double = 48000) -> [Float] {
        (0..<Int(seconds * sr)).map { amp * Float(sin(2 * .pi * f * Double($0) / sr)) }
    }

    private func midFrame(_ r: SpectrogramResult) -> Int { r.frameCount / 2 }

    // MARK: 空・不正入力の安全な扱い

    func testEmptyInputIsSafe() {
        let r = Spectrogram.analyze(mono: [], sampleRate: 48000)
        XCTAssertTrue(r.isEmpty)
        XCTAssertEqual(r.frameCount, 0)
        XCTAssertEqual(r.magnitudes, [])
        XCTAssertNil(r.peakFrequency(frame: 0))
        XCTAssertNil(r.dominantFrequency())
        XCTAssertEqual(r.magnitude(frame: 0, bin: 0), 0)
        let bands = r.displayBands(count: 32)
        XCTAssertEqual(bands.values, [Float](repeating: 0, count: 0), "空なら表示バンドも空")
    }

    func testInvalidSampleRateIsSafe() {
        for sr in [0.0, -48000.0, Double.nan, Double.infinity] {
            let r = Spectrogram.analyze(mono: sine(440, seconds: 0.1), sampleRate: sr)
            XCTAssertTrue(r.isEmpty, "sr=\(sr) は空の結果")
            XCTAssertNil(r.dominantFrequency())
        }
    }

    func testNonFiniteSamplesDoNotProduceNaN() {
        var s = sine(440, seconds: 0.5)
        s[100] = .nan; s[200] = .infinity; s[300] = -.infinity
        let r = Spectrogram.analyze(mono: s, sampleRate: 48000)
        XCTAssertFalse(r.isEmpty)
        for v in r.magnitudes { XCTAssertTrue(v.isFinite, "NaN/Inf は 0 として扱い、結果に伝播しない") }
        let peak = try? XCTUnwrap(r.peakFrequency(frame: midFrame(r)))
        XCTAssertNotNil(peak)
    }

    func testShorterThanFFTStillAnalyzes() {
        // FFT 長(2048)より短い 0.01 秒でも 1 フレームとして解析でき、ピークが概ね合う
        let r = Spectrogram.analyze(mono: sine(440, seconds: 0.01), sampleRate: 48000)
        XCTAssertEqual(r.frameCount, 1)
        let peak = try? XCTUnwrap(r.peakFrequency(frame: 0))
        XCTAssertNotNil(peak)
        if let peak { XCTAssertEqual(peak, 440, accuracy: 60, "ゼロ詰めのため粗いが 440 Hz 付近: \(peak)") }
    }

    // MARK: 無音

    func testSilenceIsZeroAndHasNoPeak() {
        let r = Spectrogram.analyze(mono: [Float](repeating: 0, count: 48000), sampleRate: 48000)
        XCTAssertFalse(r.isEmpty)
        XCTAssertEqual(r.magnitudes.max(), 0)
        for f in 0..<r.frameCount {
            XCTAssertNil(r.peakBin(frame: f), "無音のフレーム \(f) にピークは無い")
            XCTAssertNil(r.peakFrequency(frame: f))
        }
        XCTAssertNil(r.dominantFrequency())
    }

    // MARK: 単音のピーク周波数

    func testSingleSinePeakFrequency() {
        for f in [110.0, 440.0, 1000.0, 4000.0, 8000.0] {
            let r = Spectrogram.analyze(mono: sine(f, seconds: 1), sampleRate: 48000)
            let frame = midFrame(r)
            let peak = try? XCTUnwrap(r.peakFrequency(frame: frame))
            XCTAssertNotNil(peak, "\(f) Hz のピークが取れる")
            if let peak {
                // bin 間隔は 48000/2048 ≒ 23.4 Hz。放物線補間でその半分以内に収まること
                XCTAssertEqual(peak, f, accuracy: 12, "\(f) Hz: 得られた \(peak)")
            }
            let dom = try? XCTUnwrap(r.dominantFrequency())
            XCTAssertNotNil(dom)
            if let dom { XCTAssertEqual(dom, f, accuracy: 12, "\(f) Hz の支配周波数: \(dom)") }
            // ピーク bin の強さは振幅 0.5(-6 dBFS)相応に高い
            if let b = r.peakBin(frame: frame) {
                XCTAssertGreaterThan(r.magnitude(frame: frame, bin: b), 0.85)
            }
        }
    }

    func testFarBinsStayLowForPureTone() {
        let r = Spectrogram.analyze(mono: sine(440, seconds: 1), sampleRate: 48000)
        let frame = midFrame(r)
        let far = r.binIndex(forFrequency: 6000)
        XCTAssertLessThan(r.magnitude(frame: frame, bin: far), 0.15, "440 Hz の音で 6 kHz はほぼ無音")
        let near = r.binIndex(forFrequency: 440)
        XCTAssertGreaterThan(r.magnitude(frame: frame, bin: near), 0.85)
    }

    func testAnalysisIsDeterministic() {
        let s = sine(1000, seconds: 0.5)
        XCTAssertEqual(Spectrogram.analyze(mono: s, sampleRate: 48000),
                       Spectrogram.analyze(mono: s, sampleRate: 48000), "同じ入力は同じ結果(乱数なし)")
    }

    // MARK: 2音

    func testTwoSequentialTonesSwitchPeak() {
        // 前半 440 Hz、後半 2000 Hz。時刻でピークが切り替わる
        let s = sine(440, seconds: 0.5) + sine(2000, seconds: 0.5)
        let r = Spectrogram.analyze(mono: s, sampleRate: 48000)
        let early = try? XCTUnwrap(r.peakFrequency(frame: r.frameCount / 4))
        let late = try? XCTUnwrap(r.peakFrequency(frame: r.frameCount * 3 / 4))
        XCTAssertNotNil(early); XCTAssertNotNil(late)
        if let early { XCTAssertEqual(early, 440, accuracy: 15, "前半: \(early)") }
        if let late { XCTAssertEqual(late, 2000, accuracy: 20, "後半: \(late)") }
    }

    func testTwoSimultaneousTonesBothAppear() {
        let a = sine(440, seconds: 1, amp: 0.4)
        let b = sine(3000, seconds: 1, amp: 0.4)
        let mixed = zip(a, b).map { $0 + $1 }
        let r = Spectrogram.analyze(mono: mixed, sampleRate: 48000)
        let frame = midFrame(r)
        XCTAssertGreaterThan(r.magnitude(frame: frame, bin: r.binIndex(forFrequency: 440)), 0.8, "440 Hz の成分")
        XCTAssertGreaterThan(r.magnitude(frame: frame, bin: r.binIndex(forFrequency: 3000)), 0.8, "3000 Hz の成分")
        XCTAssertLessThan(r.magnitude(frame: frame, bin: r.binIndex(forFrequency: 900)), 0.3, "無い周波数は低い")
    }

    // MARK: 窓関数・ホップ・ビン対応

    func testHannWindowProperties() {
        let w = Spectrogram.hannWindow(count: 2048)
        XCTAssertEqual(w.count, 2048)
        XCTAssertEqual(w.first!, 0, accuracy: 1e-6, "両端は 0")
        XCTAssertEqual(w[1024], 1, accuracy: 1e-3, "中央は 1")
        XCTAssertEqual(Double(w.reduce(0, +)), 1024, accuracy: 1, "周期 Hann の合計は n/2")
        for i in [1, 100, 500, 1000] {
            XCTAssertEqual(w[i], w[2048 - i], accuracy: 1e-6, "対称(周期形は w[i] == w[n-i])")
        }
        XCTAssertEqual(Spectrogram.hannWindow(count: 0), [])
        XCTAssertEqual(Spectrogram.hannWindow(count: 1), [1])
    }

    func testHopAndFrameCountForOrdinarySignal() {
        // 既定: ホップ = fftSize/4(75% 重ね)。1 秒・48 kHz・FFT 2048 なら列数は上限以下で決定的
        let r = Spectrogram.analyze(mono: sine(440, seconds: 1), sampleRate: 48000)
        XCTAssertEqual(r.fftSize, 2048)
        XCTAssertEqual(r.hop, 512)
        XCTAssertEqual(r.binCount, 1024)
        XCTAssertEqual(r.frameCount, 1 + (48000 - 2048 + 511) / 512)
        XCTAssertEqual(r.magnitudes.count, r.frameCount * r.binCount)
        XCTAssertEqual(r.duration, 1, accuracy: 1e-9)
        XCTAssertFalse(r.truncated)
        // フレーム中心時刻はホップ間隔で進む
        XCTAssertEqual(r.time(forFrame: 1) - r.time(forFrame: 0), 512.0 / 48000, accuracy: 1e-9)
    }

    func testBinFrequencyRoundTrip() {
        let r = Spectrogram.analyze(mono: sine(440, seconds: 0.2), sampleRate: 48000)
        XCTAssertEqual(r.frequency(forBin: 0), 0)
        XCTAssertEqual(r.frequency(forBin: r.binCount), 24000, accuracy: 1e-9, "最上位 bin の次がナイキスト")
        for f in [40.0, 440.0, 1000.0, 5000.0, 12000.0] {
            let back = r.frequency(forBin: r.binIndex(forFrequency: f))
            XCTAssertEqual(back, f, accuracy: 12, "\(f) Hz の往復(bin 間隔 23.4 Hz の半分以内)")
        }
        XCTAssertEqual(r.binIndex(forFrequency: -100), 0, "負は端へ丸める")
        XCTAssertEqual(r.binIndex(forFrequency: 999_999), r.binCount - 1, "高すぎは端へ丸める")
    }

    // MARK: 計算量の割り切り

    func testLongSignalColumnsAreCappedByWiderHop() {
        // 30 秒でも列数は maxColumns 以下(ホップが広がる)。ピークは保たれる
        let cfg = SpectrogramConfig(maxColumns: 100)
        let r = Spectrogram.analyze(mono: sine(440, seconds: 30), sampleRate: 48000, config: cfg)
        XCTAssertLessThanOrEqual(r.frameCount, 100)
        XCTAssertGreaterThan(r.hop, 512, "列数を抑えるためホップが広がる")
        XCTAssertEqual(r.duration, 30, accuracy: 0.1)
        let peak = try? XCTUnwrap(r.peakFrequency(frame: midFrame(r)))
        XCTAssertNotNil(peak)
        if let peak { XCTAssertEqual(peak, 440, accuracy: 15) }
    }

    func testDurationCapTruncatesAndReports() {
        let cfg = SpectrogramConfig(maxDuration: 1)
        let r = Spectrogram.analyze(mono: sine(440, seconds: 3), sampleRate: 48000, config: cfg)
        XCTAssertTrue(r.truncated)
        XCTAssertEqual(r.duration, 1, accuracy: 0.02)
        XCTAssertEqual(r.sourceDuration, 3, accuracy: 1e-9)
    }

    func testConfigClamping() {
        let c = SpectrogramConfig(fftSize: 1000, maxColumns: 99999, maxDuration: -5, dynamicRangeDb: .nan).clamped
        XCTAssertEqual(c.fftSize, 512, "2 の冪へ切り下げ(1000 → 512)")
        XCTAssertEqual(c.maxColumns, SpectrogramConfig.maxColumnsRange.upperBound)
        XCTAssertEqual(c.maxDuration, SpectrogramConfig.maxDurationRange.lowerBound)
        XCTAssertEqual(c.dynamicRangeDb, 80, "NaN は既定へ")
        XCTAssertEqual(SpectrogramConfig(fftSize: 2048).clamped.fftSize, 2048)
        XCTAssertEqual(SpectrogramConfig(fftSize: 8192).clamped.fftSize, 4096, "上限へ丸める")
    }

    // MARK: 表示バンドと色

    func testDisplayBandsAreLogSpacedAndPeakAtTone() {
        let r = Spectrogram.analyze(mono: sine(440, seconds: 1), sampleRate: 48000)
        let bands = r.displayBands(count: 48)
        XCTAssertEqual(bands.bandCount, 48)
        XCTAssertEqual(bands.values.count, r.frameCount * 48)
        XCTAssertEqual(bands.edges.count, 49)
        // 対数等分: 隣り合う境目の比が一定
        XCTAssertEqual(bands.edges[2] / bands.edges[1], bands.edges[10] / bands.edges[9], accuracy: 1e-9)
        XCTAssertEqual(bands.centers[5], (bands.edges[5] * bands.edges[6]).squareRoot(), accuracy: 1e-9)
        // 440 Hz を含むバンドが最大
        let frame = midFrame(r)
        var best = 0, bestV: Float = -1
        for b in 0..<48 { let v = bands.value(frame: frame, band: b); if v > bestV { bestV = v; best = b } }
        let bandOf440 = (0..<48).first { bands.edges[$0 + 1] > 440 }!
        XCTAssertLessThanOrEqual(abs(best - bandOf440), 1,
                                 "最大バンド \(best) は 440 Hz のバンド \(bandOf440) の隣以内(ピーク bin の周波数 445 Hz 側へ寄ることがある)")
        XCTAssertGreaterThan(bestV, 0.85)
    }

    func testColorScaleEndpointsAndMonotonicBrightness() {
        let black = SpectrogramResult.color(forIntensity: 0)
        XCTAssertEqual(black.red, 0); XCTAssertEqual(black.green, 0); XCTAssertEqual(black.blue, 0)
        let white = SpectrogramResult.color(forIntensity: 1)
        XCTAssertGreaterThan(white.red + white.green + white.blue, 2.8, "最大はほぼ白")
        // 明るさ(単純和)は単調非減少
        var prev = -1.0
        for i in 0...20 {
            let c = SpectrogramResult.color(forIntensity: Float(i) / 20)
            let lum = c.red + c.green + c.blue
            XCTAssertGreaterThanOrEqual(lum + 1e-9, prev, "強さ \(i)/20 で暗くならない")
            prev = lum
            for ch in [c.red, c.green, c.blue] { XCTAssertTrue((0...1).contains(ch)) }
        }
        // 範囲外は端へ丸める
        XCTAssertEqual(SpectrogramResult.color(forIntensity: -1).red, 0)
        XCTAssertEqual(SpectrogramResult.color(forIntensity: 2).red, white.red)
        XCTAssertEqual(SpectrogramResult.color(forIntensity: .nan).red, 0)
    }

    // MARK: クリップ経路とキャッシュ

    func testSupportsChecks() {
        var audio = Clip(); audio.type = .audio; audio.src = "/tmp/x.wav"; audio.duration = 2
        XCTAssertTrue(Spectrogram.supports(audio))
        var image = Clip(); image.type = .image; image.src = "/tmp/x.png"; image.duration = 2
        XCTAssertFalse(Spectrogram.supports(image), "画像は対象外")
        var noSrc = Clip(); noSrc.type = .audio; noSrc.duration = 2
        XCTAssertFalse(Spectrogram.supports(noSrc), "素材なしは対象外")
        var frozen = Clip(); frozen.type = .video; frozen.src = "/tmp/x.mp4"; frozen.duration = 2; frozen.freeze = true
        XCTAssertFalse(Spectrogram.supports(frozen), "フリーズは無音なので対象外")
        var zero = Clip(); zero.type = .audio; zero.src = "/tmp/x.wav"; zero.duration = 0
        XCTAssertFalse(Spectrogram.supports(zero), "長さ 0 は対象外")
    }

    func testClipAnalysisFromToneFile() throws {
        let url = tmp.appendingPathComponent("tone.wav")
        try AudioFixture.writeSine(url, sampleRate: 48000, channels: 1, frequency: 880, segments: [(1.0, 0.5)])
        var c = Clip(); c.type = .audio; c.src = url.path; c.duration = 1
        let r = try XCTUnwrap(Spectrogram.analyze(clip: c), "トーン WAV のクリップを解析できるはず")
        XCTAssertEqual(r.sampleRate, 48000, accuracy: 1e-9, "ミキサー経路は 48 kHz")
        XCTAssertEqual(r.duration, 1, accuracy: 0.05)
        let peak = try XCTUnwrap(r.dominantFrequency())
        XCTAssertEqual(peak, 880, accuracy: 15, "支配周波数: \(peak)")
        // 読めない素材は nil(落とさない)
        var bad = Clip(); bad.type = .audio; bad.src = tmp.appendingPathComponent("none.wav").path; bad.duration = 1
        XCTAssertNil(Spectrogram.analyze(clip: bad))
    }

    func testCacheRoundTripAndClipKey() throws {
        let cache = SpectrogramCache(budget: nil)
        let url = tmp.appendingPathComponent("cache-tone.wav")
        try AudioFixture.writeSine(url, sampleRate: 48000, channels: 1, frequency: 440, segments: [(0.5, 0.5)])
        var c = Clip(); c.id = "spec-cache-1"; c.type = .audio; c.src = url.path; c.duration = 0.5
        let first = try XCTUnwrap(cache.spectrogram(clip: c))
        XCTAssertEqual(cache.count, 1)
        let second = try XCTUnwrap(cache.spectrogram(clip: c))
        XCTAssertEqual(first, second, "2 回目はキャッシュから同じ結果")
        XCTAssertEqual(cache.count, 1)
        // 設定が違えばキーが違う(別エントリになる)
        let other = SpectrogramConfig(fftSize: 1024)
        XCTAssertNotEqual(Spectrogram.cacheKey(for: c), Spectrogram.cacheKey(for: c, config: other))
        cache.purge()
        XCTAssertEqual(cache.count, 0)
        _ = first
    }
}
