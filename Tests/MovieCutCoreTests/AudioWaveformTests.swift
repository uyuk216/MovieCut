import XCTest
@testable import MovieCutCore

/// X-2 音声波形: 純粋な集計・ファイル生成・メモリキャッシュ(予算配下)。
final class AudioWaveformTests: XCTestCase {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("waveform-tests-\(UUID().uuidString)")
    override func setUpWithError() throws { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func testSilenceHasZeroPeaks() {
        let wf = AudioWaveform.waveform(mono: [Float](repeating: 0, count: 1000), bucketCount: 10, duration: 1)
        XCTAssertEqual(wf.bucketCount, 10)
        XCTAssertEqual(wf.peaks, [Float](repeating: 0, count: 10))
        XCTAssertEqual(wf.duration, 1)
    }

    func testSinePeaksMatchAmplitude() {
        let sr = 8000.0
        let samples = (0..<8000).map { Float(0.5 * sin(2 * Double.pi * 440 * Double($0) / sr)) }
        let wf = AudioWaveform.waveform(mono: samples, bucketCount: 8, duration: 1)
        for peak in wf.peaks {
            XCTAssertEqual(peak, 0.5, accuracy: 0.02, "正弦波のピークは振幅に一致")
        }
    }

    func testImpulseLandsInItsBucketWithSign() {
        var samples = [Float](repeating: 0, count: 1000)
        samples[500] = 1.0
        samples[100] = -0.8
        let wf = AudioWaveform.waveform(mono: samples, bucketCount: 10, duration: 1)
        XCTAssertEqual(wf.peaks[5], 1.0)
        XCTAssertEqual(wf.maximums[5], 1.0)
        XCTAssertEqual(wf.minimums[1], -0.8)
        XCTAssertEqual(wf.peaks[1], 0.8)
        for i in [0, 2, 3, 4, 6, 7, 8, 9] { XCTAssertEqual(wf.peaks[i], 0, "インパルスの無いバケットは 0") }
    }

    func testAccumulatorChunkedEqualsOneShot() {
        let samples = (0..<5000).map { Float(sin(Double($0) * 0.01)) * Float($0 % 7) / 7 }
        let oneShot = AudioWaveform.waveform(mono: samples, bucketCount: 25, duration: 2)
        var acc = WaveformAccumulator(totalFrames: samples.count, bucketCount: 25)
        acc.append(mono: Array(samples[0..<1000]))
        acc.append(mono: Array(samples[1000..<4321]))
        acc.append(mono: Array(samples[4321..<5000]))
        XCTAssertEqual(acc.finish(duration: 2), oneShot, "少しずつ流しても一括と同じ波形")
    }

    func testDownmixAveragesChannels() {
        let mixed = AudioWaveform.downmix([[1, -1, 0.5], [0.5, -0.5, 0.5]])
        XCTAssertEqual(mixed.count, 3)
        XCTAssertEqual(mixed[0], 0.75, accuracy: 1e-6)
        XCTAssertEqual(mixed[1], -0.75, accuracy: 1e-6)
        XCTAssertEqual(mixed[2], 0.5, accuracy: 1e-6)
        XCTAssertEqual(AudioWaveform.downmix([]), [])
        XCTAssertEqual(AudioWaveform.downmix([[0.25, 0.5]]), [0.25, 0.5], "1 チャンネルはそのまま")
    }

    func testBarHeightsResampling() {
        let wf = AudioWaveformData(minimums: [0, -1, 0, 0], maximums: [0, 0.5, 0, 0.25], duration: 1)
        XCTAssertEqual(wf.peaks, [0, 1, 0, 0.25])
        XCTAssertEqual(wf.barHeights(count: 4), wf.peaks, "同数はそのまま")
        XCTAssertEqual(wf.barHeights(count: 2), [1, 0.25], "間引きは最大プーリング")
        XCTAssertEqual(wf.barHeights(count: 8), [0, 0, 1, 1, 0, 0, 0.25, 0.25], "引き伸ばしは最近傍")
        XCTAssertEqual(wf.barHeights(count: 0), [])
        XCTAssertEqual(AudioWaveformData(minimums: [], maximums: [], duration: 0).barHeights(count: 3), [0, 0, 0])
    }

    func testGenerateFromToneFile() async throws {
        let url = tmp.appendingPathComponent("tone.wav")
        try ToneVoiceProvider.writeTone(to: url, duration: 1.2, frequency: 330)
        let wf = await AudioWaveform.generate(url: url, bucketCount: 24)
        let data = try XCTUnwrap(wf, "トーン WAV から波形が作れるはず")
        XCTAssertEqual(data.bucketCount, 24)
        XCTAssertEqual(data.duration, 1.2, accuracy: 0.05)
        // トーンは全体に鳴っている(4 Hz の強弱つき)ので、ほとんどのバケットに音がある
        let sounding = data.peaks.filter { $0 > 0.08 }.count
        XCTAssertGreaterThan(sounding, 20)
        for peak in data.peaks { XCTAssertLessThanOrEqual(peak, 0.51) }
        let maxPeak = data.peaks.max() ?? 0
        XCTAssertGreaterThan(maxPeak, 0.3, "一番大きいピークは振幅 0.5 に近い")
        XCTAssertLessThanOrEqual(maxPeak, 0.51)
    }

    func testGenerateReturnsNilForGarbageAndMissing() async throws {
        let bad = tmp.appendingPathComponent("bad.wav")
        try Data(repeating: 0x42, count: 128).write(to: bad)
        let none = await AudioWaveform.generate(url: bad)
        XCTAssertNil(none, "壊れたファイルは nil(画面はアイコン表示へフォールバック)")
        let missing = await AudioWaveform.generate(url: tmp.appendingPathComponent("none.wav"))
        XCTAssertNil(missing)
    }

    func testCacheKeyTracksFileReplacement() throws {
        let url = tmp.appendingPathComponent("k.wav")
        try Data(repeating: 1, count: 100).write(to: url)
        let k1 = AudioWaveform.cacheKey(url: url, bucketCount: 10)
        try Data(repeating: 1, count: 200).write(to: url)
        let k2 = AudioWaveform.cacheKey(url: url, bucketCount: 10)
        XCTAssertNotEqual(k1, k2, "大きさが変わればキーが変わる(古い波形を使い回さない)")
        XCTAssertNotEqual(k1, AudioWaveform.cacheKey(url: url, bucketCount: 20), "バケット数でも変わる")
    }

    func testCacheEvictsLRUUnderBudget() {
        // 1 件 144 バイト(10 バケット)。上限 200 なら 1 件だけ残る
        let cache = WaveformCache(budget: CacheBudgetManager(limitBytes: 200))
        let d = AudioWaveformData(minimums: [Float](repeating: 0, count: 10),
                                  maximums: [Float](repeating: 0.5, count: 10), duration: 1)
        XCTAssertEqual(d.byteCost, 144)
        cache.store(d, key: "a")
        XCTAssertNotNil(cache.cached(key: "a"))
        cache.store(d, key: "b")
        XCTAssertNil(cache.cached(key: "a"), "予算超過で古い方(LRU)が破棄される")
        XCTAssertNotNil(cache.cached(key: "b"))
        XCTAssertEqual(cache.count, 1)
    }

    func testCacheRejectsOversizedSingleEntry() {
        // 1 件で上限を超えるものは覚えない(上限を絶対に超えない方針と一致)
        let cache = WaveformCache(budget: CacheBudgetManager(limitBytes: 100))
        let d = AudioWaveformData(minimums: [Float](repeating: 0, count: 10),
                                  maximums: [Float](repeating: 0.5, count: 10), duration: 1)
        cache.store(d, key: "big")
        XCTAssertNil(cache.cached(key: "big"))
        XCTAssertEqual(cache.count, 0)
    }

    func testCacheRoundTripThroughFile() async throws {
        let url = tmp.appendingPathComponent("cached.wav")
        try ToneVoiceProvider.writeTone(to: url, duration: 0.6, frequency: 220)
        let cache = WaveformCache(budget: CacheBudgetManager(limitBytes: 1_000_000))
        let first = await cache.waveform(url: url, bucketCount: 12)
        XCTAssertNotNil(first)
        XCTAssertEqual(cache.count, 1)
        let second = await cache.waveform(url: url, bucketCount: 12)
        XCTAssertEqual(first, second, "2 回目はキャッシュから同じ波形")
        // バケット数が違えば別エントリ
        let other = await cache.waveform(url: url, bucketCount: 30)
        XCTAssertEqual(other?.bucketCount, 30)
        XCTAssertEqual(cache.count, 2)
    }
}
