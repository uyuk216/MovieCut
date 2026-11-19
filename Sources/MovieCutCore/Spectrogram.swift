import Foundation
import Accelerate

// MARK: - 音声スペクトログラム(周波数 × 時間の表示)
//
// Premiere Pro の「スペクトル表示」/ Audition のスペクトログラム相当。
// 音声を短時間フーリエ変換(STFT)し、時刻ごとの周波数成分の強さを 0〜1 で返す純粋な計算部品。
// 画面は持たない。表示はアプリ側(`ScopeSheet`)が `SpectrogramResult` を色へ写して描く。
//
// 既存部品との関係:
// - `SpectrumAnalyzer`(ビジュアライザのスペクトルモード)は 1/60 秒ごとの対数バンド列で、
//   時間方向の平滑化(アタック/ディケイ)を含む描画専用の値。スペクトログラムは平滑化せず、
//   線形ビンのまま保持してピーク周波数を読み取れる形にした(用途が違うため共用しない)。
// - `SpectralDenoise` の STFT はノイズ除去専用で内部型のため再利用できない。窓・FFT の
//   作法(Hann 窓、vDSP の実数 FFT、振幅 1 の正弦波が 1 になる正規化)はそちらに合わせた。
// - クリップからの読み込みは `SilenceDetector.analyze` と同じ経路
//   (`AudioMixer.openSource`、48 kHz ステレオ → モノラル平均)を使う。
//
// 計算量の割り切り(長尺で固まらないため):
// - 解析する長さは先頭 `maxDuration`(既定 60 秒)まで。超えた分は読まず、`truncated` で知らせる。
// - 時間方向の列数は `maxColumns`(既定 480)以下になるようホップを広げる
//   (短い素材はホップ = FFT 長 / 4 の 75% 重ね、長い素材は列数優先で間引く)。
// - 結果は表示専用のキャッシュ扱い(`SpectrogramCache`、メモリのみ)。プロジェクト保存には入れない。

/// スペクトログラムの計算設定。範囲外の値は `clamped` で丸める。
public struct SpectrogramConfig: Equatable, Sendable {
    /// FFT の点数(2 の冪)。周波数分解能 = サンプルレート / fftSize。
    public var fftSize: Int
    /// 時間方向の最大列数。これを超えないようホップを広げる。
    public var maxColumns: Int
    /// 解析する最大の長さ(秒)。先頭からこの長さだけを読む。
    public var maxDuration: Double
    /// 0〜1 へ写すダイナミックレンジ(dB)。0 dBFS が 1、-dynamicRangeDb 以下が 0。
    public var dynamicRangeDb: Double

    public static let fftSizeRange: ClosedRange<Int> = 256...4096
    public static let maxColumnsRange: ClosedRange<Int> = 16...1024
    public static let maxDurationRange: ClosedRange<Double> = 1...600
    public static let dynamicRangeDbRange: ClosedRange<Double> = 20...120
    public static let `default` = SpectrogramConfig()

    public init(fftSize: Int = 2048, maxColumns: Int = 480, maxDuration: Double = 60, dynamicRangeDb: Double = 80) {
        self.fftSize = fftSize
        self.maxColumns = maxColumns
        self.maxDuration = maxDuration
        self.dynamicRangeDb = dynamicRangeDb
    }

    /// 範囲に収め、fftSize を 2 の冪へ丸めた値。
    public var clamped: SpectrogramConfig {
        var n = min(max(fftSize, Self.fftSizeRange.lowerBound), Self.fftSizeRange.upperBound)
        // 2 の冪へ切り下げる(256 以上は必ず 2 の冪が範囲内にある)
        var p = 256
        while p * 2 <= n { p *= 2 }
        n = p
        func cd(_ v: Double, _ r: ClosedRange<Double>, _ d: Double) -> Double {
            v.isFinite ? min(max(v, r.lowerBound), r.upperBound) : d
        }
        return SpectrogramConfig(
            fftSize: n,
            maxColumns: min(max(maxColumns, Self.maxColumnsRange.lowerBound), Self.maxColumnsRange.upperBound),
            maxDuration: cd(maxDuration, Self.maxDurationRange, 60),
            dynamicRangeDb: cd(dynamicRangeDb, Self.dynamicRangeDbRange, 80))
    }
}

/// スペクトログラムの結果。`magnitudes` は frame × bin の平らな配列
/// (`magnitudes[frame * binCount + bin]`、値 0〜1)。bin は線形周波数で、
/// bin k の周波数 = k × sampleRate / fftSize(bin 0 は直流)。
public struct SpectrogramResult: Equatable, Sendable {
    public var magnitudes: [Float]
    public var frameCount: Int
    public var binCount: Int
    public var fftSize: Int
    /// フレーム間のサンプル数(ホップ)。
    public var hop: Int
    public var sampleRate: Double
    /// 実際に解析した長さ(秒)。
    public var duration: Double
    /// 素材全体の長さ(秒)。切り捨てたときは duration より大きい。
    public var sourceDuration: Double
    /// `maxDuration` で先頭だけを解析したか。
    public var truncated: Bool
    public var dynamicRangeDb: Double

    public init(magnitudes: [Float], frameCount: Int, binCount: Int, fftSize: Int, hop: Int,
                sampleRate: Double, duration: Double, sourceDuration: Double, truncated: Bool, dynamicRangeDb: Double) {
        let frames = max(0, frameCount), bins = max(0, binCount)
        self.magnitudes = magnitudes.count == frames * bins ? magnitudes : [Float](repeating: 0, count: frames * bins)
        self.frameCount = frames
        self.binCount = bins
        self.fftSize = max(2, fftSize)
        self.hop = max(1, hop)
        self.sampleRate = sampleRate
        self.duration = max(0, duration)
        self.sourceDuration = max(0, sourceDuration)
        self.truncated = truncated
        self.dynamicRangeDb = dynamicRangeDb
    }

    /// 空の結果(データなし)。ピーク系はすべて nil を返す。
    public static func empty(fftSize: Int = SpectrogramConfig.default.fftSize, sampleRate: Double = 48000) -> SpectrogramResult {
        SpectrogramResult(magnitudes: [], frameCount: 0, binCount: fftSize / 2, fftSize: fftSize, hop: fftSize / 4,
                          sampleRate: sampleRate, duration: 0, sourceDuration: 0, truncated: false,
                          dynamicRangeDb: SpectrogramConfig.default.dynamicRangeDb)
    }

    public var isEmpty: Bool { frameCount == 0 || binCount == 0 }

    /// キャッシュのバイトコスト見積もり。
    public var byteCost: Int { magnitudes.count * 4 + 128 }

    /// 1 マスの強さ(範囲外は 0)。
    public func magnitude(frame: Int, bin: Int) -> Float {
        guard frame >= 0, frame < frameCount, bin >= 0, bin < binCount else { return 0 }
        return magnitudes[frame * binCount + bin]
    }

    /// フレームの中心時刻(秒)。
    public func time(forFrame frame: Int) -> Double {
        guard sampleRate > 0 else { return 0 }
        return (Double(frame) * Double(hop) + Double(fftSize) / 2) / sampleRate
    }

    /// bin の周波数(Hz)。
    public func frequency(forBin bin: Int) -> Double {
        guard fftSize > 0, sampleRate > 0 else { return 0 }
        return Double(min(max(bin, 0), binCount)) * sampleRate / Double(fftSize)
    }

    /// 周波数に最も近い bin(直流 bin 0 も含む。範囲外は端へ丸める)。
    public func binIndex(forFrequency f: Double) -> Int {
        guard binCount > 0, fftSize > 0, sampleRate > 0, f.isFinite else { return 0 }
        let k = Int((f * Double(fftSize) / sampleRate).rounded())
        return min(max(k, 0), binCount - 1)
    }

    /// フレーム内で最も強い bin(直流 bin 0 は除く)。全部 0 のときは nil。
    public func peakBin(frame: Int) -> Int? {
        guard frame >= 0, frame < frameCount, binCount > 1 else { return nil }
        var best = 0, bestV: Float = 0
        for b in 1..<binCount {
            let v = magnitudes[frame * binCount + b]
            if v > bestV { bestV = v; best = b }
        }
        return bestV > 0 ? best : nil
    }

    /// フレーム内で最も強い成分の周波数(Hz)。ピーク bin の前後で放物線補間し、
    /// bin 間隔より細かく読む。音が無いフレームは nil。
    public func peakFrequency(frame: Int) -> Double? {
        guard let k = peakBin(frame: frame) else { return nil }
        return interpolatedFrequency(frame: frame, bin: k)
    }

    /// 全体で最も強い 1 マスの周波数(Hz)。音が無ければ nil。
    public func dominantFrequency() -> Double? {
        guard frameCount > 0, binCount > 1 else { return nil }
        var bestFrame = -1, bestBin = 0, bestV: Float = 0
        for f in 0..<frameCount {
            for b in 1..<binCount {
                let v = magnitudes[f * binCount + b]
                if v > bestV { bestV = v; bestFrame = f; bestBin = b }
            }
        }
        guard bestFrame >= 0, bestV > 0 else { return nil }
        return interpolatedFrequency(frame: bestFrame, bin: bestBin)
    }

    /// bin k の前後の値(0〜1 は dB の線形写像なので、そのまま放物線補間に使える)から頂点の周波数を読む。
    private func interpolatedFrequency(frame: Int, bin k: Int) -> Double {
        guard k > 0, k < binCount - 1 else { return frequency(forBin: k) }
        let a = Double(magnitude(frame: frame, bin: k - 1))
        let b = Double(magnitude(frame: frame, bin: k))
        let c = Double(magnitude(frame: frame, bin: k + 1))
        let denom = a - 2 * b + c
        guard denom != 0 else { return frequency(forBin: k) }
        let delta = min(1, max(-1, 0.5 * (a - c) / denom))
        return (Double(k) + delta) * sampleRate / Double(fftSize)
    }

    /// 表示用に対数バンドへまとめた結果(最大プーリング)。
    /// 線形 bin のままでは低域が潰れて見えないため、画面ではこちらを使う。
    public func displayBands(count requested: Int, minFrequency: Double = 20, maxFrequency: Double? = nil) -> SpectrogramDisplayBands {
        let count = max(1, requested)
        let nyquist = sampleRate / 2
        let lo = min(max(minFrequency.isFinite ? minFrequency : 20, 1), max(10, nyquist - 1))
        let hi = min(max(maxFrequency ?? nyquist, lo * 1.01), max(lo * 1.01, nyquist))
        let edges = (0...count).map { lo * pow(hi / lo, Double($0) / Double(count)) }
        let centers = (0..<count).map { (edges[$0] * edges[$0 + 1]).squareRoot() }
        var values = [Float](repeating: 0, count: frameCount * count)
        guard !isEmpty else {
            return SpectrogramDisplayBands(values: values, frameCount: frameCount, bandCount: count, edges: edges, centers: centers)
        }
        for band in 0..<count {
            var bLo = binIndex(forFrequency: edges[band])
            var bHi = binIndex(forFrequency: edges[band + 1])
            if band > 0 { bLo = max(bLo, 1) }   // 直流は最低帯だけに含める
            if bHi <= bLo { bHi = bLo + 1 }
            bHi = min(bHi, binCount)
            bLo = min(bLo, binCount - 1)
            for f in 0..<frameCount {
                var m: Float = 0
                for b in bLo..<bHi { m = max(m, magnitudes[f * binCount + b]) }
                values[f * count + band] = m
            }
        }
        return SpectrogramDisplayBands(values: values, frameCount: frameCount, bandCount: count, edges: edges, centers: centers)
    }

    /// 強さ 0〜1 の色(止め点を線形補間)。暗い紫 → 赤紫 → 橙 → 黄 → 白の単調に明るくなる色階調。
    /// 画面を持たない純粋関数なので、アプリ側はこの RGB をそのまま使える。
    public static func color(forIntensity v: Float) -> (red: Double, green: Double, blue: Double) {
        let stops: [(Double, (Double, Double, Double))] = [
            (0.0, (0, 0, 0)),
            (0.2, (0.16, 0.03, 0.35)),
            (0.45, (0.55, 0.08, 0.45)),
            (0.65, (0.90, 0.30, 0.15)),
            (0.85, (0.98, 0.70, 0.15)),
            (1.0, (1.0, 1.0, 0.90)),
        ]
        let x = Double(min(max(v.isFinite ? v : 0, 0), 1))
        for i in 1..<stops.count where x <= stops[i].0 {
            let (x0, c0) = stops[i - 1], (x1, c1) = stops[i]
            let t = x1 > x0 ? (x - x0) / (x1 - x0) : 0
            return (c0.0 + (c1.0 - c0.0) * t, c0.1 + (c1.1 - c0.1) * t, c0.2 + (c1.2 - c0.2) * t)
        }
        let last = stops[stops.count - 1].1
        return (last.0, last.1, last.2)
    }
}

/// 対数バンドへまとめた表示用データ。`values[frame * bandCount + band]`(0〜1)。
public struct SpectrogramDisplayBands: Equatable, Sendable {
    public var values: [Float]
    public var frameCount: Int
    public var bandCount: Int
    /// バンドの境目の周波数(bandCount + 1 個、Hz)。
    public var edges: [Double]
    /// バンドの中心周波数(幾何平均、Hz)。
    public var centers: [Double]

    public init(values: [Float], frameCount: Int, bandCount: Int, edges: [Double], centers: [Double]) {
        self.values = values
        self.frameCount = frameCount
        self.bandCount = bandCount
        self.edges = edges
        self.centers = centers
    }

    public func value(frame: Int, band: Int) -> Float {
        guard frame >= 0, frame < frameCount, band >= 0, band < bandCount else { return 0 }
        return values[frame * bandCount + band]
    }
}

public enum Spectrogram {
    /// Hann 窓(周期形。長さ n、合計は n/2)。STFT の窓として使う純粋関数。
    public static func hannWindow(count n: Int) -> [Float] {
        guard n > 0 else { return [] }
        if n == 1 { return [1] }
        return (0..<n).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n))) }
    }

    /// スペクトログラムを表示できるクリップか: 音の出る素材(音声・ボイス・動画)で素材を持ち、長さがあるもの。
    /// フリーズフレームは `supportsAudioFx` の条件で対象外。速度・逆再生のあるクリップも対象だが、
    /// 解析は素材の時間軸で行う(ピッチ変換後の聞こえ方ではない。docs 参照)。
    public static func supports(_ c: Clip) -> Bool {
        Clip.supportsAudioFx(c) && (c.src.map { !$0.isEmpty } ?? false) && c.duration > 0
    }

    /// モノラルサンプル列からスペクトログラムを作る(純粋関数、決定的)。
    /// 空・サンプルレート不正のときは空の結果を返す(落とさない)。
    public static func analyze(mono samples: [Float], sampleRate sr: Double, config rawConfig: SpectrogramConfig = .default) -> SpectrogramResult {
        let config = rawConfig.clamped
        let sourceDuration = (sr > 0 && sr.isFinite) ? Double(samples.count) / sr : 0
        return analyze(mono: samples, sampleRate: sr, config: config, sourceDuration: sourceDuration)
    }

    private static func analyze(mono samples: [Float], sampleRate sr: Double, config: SpectrogramConfig, sourceDuration: Double) -> SpectrogramResult {
        let n = config.fftSize
        let half = n / 2
        guard sr > 0, sr.isFinite, !samples.isEmpty else {
            return SpectrogramResult(magnitudes: [], frameCount: 0, binCount: half, fftSize: n, hop: n / 4,
                                     sampleRate: sr.isFinite ? sr : 0, duration: 0, sourceDuration: sourceDuration,
                                     truncated: false, dynamicRangeDb: config.dynamicRangeDb)
        }
        // 先頭 maxDuration までで打ち切る
        let cap = Int((config.maxDuration * sr).rounded())
        let truncated = samples.count > cap
        let usable = truncated ? Array(samples.prefix(max(0, cap))) : samples
        let count = usable.count
        // ホップ: 既定は fftSize/4。列数が maxColumns を超えるなら広げる
        let baseHop = max(1, n / 4)
        var hop = baseHop
        if count > n {
            let framesAtBase = 1 + (count - n + baseHop - 1) / baseHop
            if framesAtBase > config.maxColumns {
                hop = max(baseHop, (count - n + config.maxColumns - 2) / max(1, config.maxColumns - 1))
            }
        }
        let frames = count <= n ? 1 : 1 + (count - n + hop - 1) / hop
        let log2n = vDSP_Length(Int(log2(Double(n))))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(FFT_RADIX2)) else {
            return SpectrogramResult(magnitudes: [], frameCount: 0, binCount: half, fftSize: n, hop: hop,
                                     sampleRate: sr, duration: 0, sourceDuration: sourceDuration,
                                     truncated: truncated, dynamicRangeDb: config.dynamicRangeDb)
        }
        defer { vDSP_destroy_fftsetup(setup) }
        let window = hannWindow(count: n)
        var out = [Float](repeating: 0, count: frames * half)
        var frame = [Float](repeating: 0, count: n)
        var re = [Float](repeating: 0, count: half), im = [Float](repeating: 0, count: half)
        let norm = Float(2.0 / Double(n))   // zrip の出力は DFT の 2 倍。Hann 窓つきでも振幅 1 の正弦波(bin 中心)が 1 になる
        let range = config.dynamicRangeDb
        for f in 0..<frames {
            let start = f * hop
            for i in 0..<n {
                let j = start + i
                let s = (j >= 0 && j < count) ? usable[j] : 0
                frame[i] = (s.isFinite ? s : 0) * window[i]
            }
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    frame.withUnsafeBufferPointer { fp in
                        fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                            vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                }
            }
            for b in 0..<half {
                let amp = (re[b] * re[b] + im[b] * im[b]).squareRoot() * norm
                let db = 20 * log10(Double(max(amp, 1e-12)))
                out[f * half + b] = Float(min(1, max(0, (db + range) / range)))
            }
        }
        return SpectrogramResult(magnitudes: out, frameCount: frames, binCount: half, fftSize: n, hop: hop,
                                 sampleRate: sr, duration: Double(count) / sr, sourceDuration: sourceDuration,
                                 truncated: truncated, dynamicRangeDb: range)
    }

    /// クリップの音(素材の範囲 [offset, offset + 素材の長さ])からスペクトログラムを作る。
    /// ミキサーと同じ経路で 48 kHz ステレオを読み、左右の平均でモノラル化する。
    /// 読めない・音が無いときは nil。先頭 `maxDuration` を超える分は読まない。
    public static func analyze(clip c: Clip, config rawConfig: SpectrogramConfig = .default) -> SpectrogramResult? {
        guard supports(c) else { return nil }
        let config = rawConfig.clamped
        let span = ClipTiming.sourceSpan(c)
        guard span > 0, let source = try? AudioMixer.openSource(c, offset: c.offset, span: span) else { return nil }
        let sr = AudioMixer.sampleRate
        let want = Int((min(span, config.maxDuration) * sr).rounded())
        guard want > 0 else { return nil }
        let chunk = 16384
        let l = UnsafeMutablePointer<Float>.allocate(capacity: chunk), r = UnsafeMutablePointer<Float>.allocate(capacity: chunk)
        defer { l.deallocate(); r.deallocate() }
        var mono: [Float] = []
        mono.reserveCapacity(want)
        var done = 0
        while done < want {
            let got = source.read(left: l, right: r, frames: min(chunk, want - done))
            if got <= 0 { break }
            for i in 0..<got { mono.append((l[i] + r[i]) * 0.5) }
            done += got
        }
        guard !mono.isEmpty else { return nil }
        var result = analyze(mono: mono, sampleRate: sr, config: config, sourceDuration: span)
        // 素材が span より短く読めた場合は、切り捨てではなく素材切れなので truncated は span との差で決め直す
        result.truncated = span > config.maxDuration + 1e-9 && done >= want
        return result
    }

    /// キャッシュキー: クリップ id + 素材パス・大きさ・更新時刻 + 設定(差し替えと設定違いを検出するため)。
    public static func cacheKey(for c: Clip, config rawConfig: SpectrogramConfig = .default) -> String {
        let config = rawConfig.clamped
        var filePart = ""
        if let src = c.src, !src.isEmpty {
            let attrs = try? FileManager.default.attributesOfItem(atPath: src)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? -1
            let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
            filePart = "\(src)|\(size)|\(mtime)"
        }
        return "spectrogram|\(c.id)|\(filePart)|\(c.offset)|\(ClipTiming.sourceSpan(c))|\(config.fftSize)|\(config.maxColumns)|\(config.maxDuration)|\(config.dynamicRangeDb)"
    }
}

/// スペクトログラムのメモリキャッシュ。`CacheBudgetManager` 配下で LRU 破棄され、ディスクには書かない。
/// 波形の `WaveformCache` と同じ作法。プロジェクト保存には一切関与しない。
public final class SpectrogramCache: @unchecked Sendable {
    public static let shared = SpectrogramCache(budget: CacheBudgetManager(limitBytes: MemoryBudget.currentLimitBytes(platform: .mac)))

    private let lock = NSLock()
    private var store: [String: SpectrogramResult] = [:]
    public let budget: CacheBudgetManager?

    public init(budget: CacheBudgetManager?) {
        self.budget = budget
    }

    /// 登録中の件数(テスト・診断用)。
    public var count: Int { lock.lock(); defer { lock.unlock() }; return store.count }

    public func cached(key: String) -> SpectrogramResult? {
        lock.lock()
        let value = store[key]
        lock.unlock()
        if value != nil { budget?.touch(key) }
        return value
    }

    public func store(_ data: SpectrogramResult, key: String) {
        lock.lock(); store[key] = data; lock.unlock()
        budget?.register(key: key, cost: Int64(data.byteCost)) { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.store[key] = nil; self.lock.unlock()
        }
    }

    public func purge() {
        lock.lock(); store.removeAll(); lock.unlock()
        budget?.purgeAll()
    }

    /// クリップのスペクトログラム: キャッシュにあればそれ、無ければ作って覚える。作れなければ nil。
    public func spectrogram(clip c: Clip, config: SpectrogramConfig = .default) -> SpectrogramResult? {
        let key = Spectrogram.cacheKey(for: c, config: config)
        if let hit = cached(key: key) { return hit }
        guard let data = Spectrogram.analyze(clip: c, config: config) else { return nil }
        store(data, key: key)
        return data
    }
}
