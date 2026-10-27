import Foundation
import AVFoundation

/// A6: タイムラインの波形(ピークの包絡線)とサムネイルの選び方。描画から切り離した純粋な計算と、非同期の読み込み。

// MARK: - 波形

/// 素材の音のピーク(1/100 秒ごとの最大の絶対値 0...1)。
public struct WaveformPeaks: Equatable, Sendable {
    /// 1 秒あたりのピークの数。
    public static let perSecond = 100
    public var peaks: [Float]

    public init(peaks: [Float]) { self.peaks = peaks }

    public var duration: Double { Double(peaks.count) / Double(Self.perSecond) }

    /// 流れてくるサンプルから、順にピークを作る(長い素材をまるごとメモリに置かないため)。
    public struct Accumulator {
        let sampleRate: Double
        /// 1 フレームあたりのサンプル数(インターリーブされたチャンネル数)。ピークはどのチャンネルのものでも最大を取る。
        let channels: Int
        private(set) var peaks: [Float] = []
        private var index = 0          // これまでに見たサンプルの数
        private var current: Float = 0
        private var bucket = 0

        public init(sampleRate: Double, channels: Int = 1) { self.sampleRate = max(1, sampleRate); self.channels = max(1, channels) }

        public mutating func append(_ samples: UnsafeBufferPointer<Float>) {
            for s in samples {
                let b = Int(Double(index / channels) * Double(WaveformPeaks.perSecond) / sampleRate)
                if b != bucket {
                    peaks.append(current)
                    // 飛んだぶんは 0 で埋める(通常は 1 つずつ進む)
                    if b > bucket + 1 { peaks.append(contentsOf: [Float](repeating: 0, count: b - bucket - 1)) }
                    bucket = b
                    current = 0
                }
                let a = abs(s)
                if a > current { current = a }
                index += 1
            }
        }

        public mutating func append(_ samples: [Float]) {
            samples.withUnsafeBufferPointer { append($0) }
        }

        public func finish() -> WaveformPeaks {
            var p = peaks
            if index > 0 { p.append(current) }
            return WaveformPeaks(peaks: p.map { min(1, $0) })
        }
    }

    /// サンプル列(モノラル)からピークを作る。
    public static func compute(samples: [Float], sampleRate: Double) -> WaveformPeaks {
        var acc = Accumulator(sampleRate: sampleRate)
        acc.append(samples)
        return acc.finish()
    }

    /// 素材の [from, to] 秒を `count` 本の縦線に分けたときの、それぞれの最大のピーク。`from > to` なら逆順(逆再生)。
    /// 範囲が素材の外なら 0。
    public func columns(from: Double, to: Double, count: Int) -> [Float] {
        guard count > 0 else { return [] }
        let reversed = from > to
        let lo = min(from, to), hi = max(from, to)
        let span = hi - lo
        var out = [Float](repeating: 0, count: count)
        guard span > 0, !peaks.isEmpty else { return out }
        let per = Double(Self.perSecond)
        for i in 0..<count {
            let a = lo + span * Double(i) / Double(count)
            let b = lo + span * Double(i + 1) / Double(count)
            var i0 = Int((a * per).rounded(.down)), i1 = Int((b * per).rounded(.up)) - 1
            i0 = max(0, i0); i1 = min(peaks.count - 1, max(i0, i1))
            guard i0 <= i1, i0 < peaks.count else { continue }
            var m: Float = 0
            for k in i0...i1 where peaks[k] > m { m = peaks[k] }
            out[i] = m
        }
        return reversed ? out.reversed() : out
    }

    /// クリップが見せる素材の範囲(左端 → 右端の素材の秒)。逆再生は左端が素材の終わり側。速度は範囲の広さに効く。
    public static func sourceRange(for c: Clip) -> (from: Double, to: Double) {
        let span = c.duration * c.effectiveSpeed
        return c.effectiveReverse ? (c.offset + span, c.offset) : (c.offset, c.offset + span)
    }

    /// クリップの波形の縦線(`count` 本)。フリーズフレームは音が無いので空。
    public func columns(for c: Clip, count: Int) -> [Float] {
        guard !c.isFreeze else { return [Float](repeating: 0, count: max(0, count)) }
        let r = Self.sourceRange(for: c)
        return columns(from: r.from, to: r.to, count: count)
    }

    /// 音のある素材のピークを読む(AVAssetReader でモノラルに落として流し読み)。音が無い・読めないときは nil。
    public static func load(url: URL) async -> WaveformPeaks? {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio), let track = tracks.first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let rate = 8000.0
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 2,   // 左右のどちらかが大きければそれを見る(モノラルへの混ぜ合わせで音量が変わらないように)
            AVSampleRateKey: rate,
        ])
        out.alwaysCopiesSampleData = false
        guard reader.canAdd(out) else { return nil }
        reader.add(out)
        guard reader.startReading() else { return nil }
        var acc = Accumulator(sampleRate: rate, channels: 2)
        while let sb = out.copyNextSampleBuffer() {
            if Task.isCancelled { reader.cancelReading(); return nil }
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
            var length = 0
            var ptr: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &ptr) == kCMBlockBufferNoErr,
                  let base = ptr else { continue }
            base.withMemoryRebound(to: Float.self, capacity: length / 4) { acc.append(UnsafeBufferPointer(start: $0, count: length / 4)) }
        }
        guard reader.status == .completed else { return nil }
        let result = acc.finish()
        return result.peaks.isEmpty ? nil : result
    }
}

// MARK: - サムネイル

/// サムネイルの時刻の選び方(拡大率に合わせて数を決め、近い時刻に丸めてキャッシュを使い回す)。
public enum ThumbnailPlan {
    /// 丸めの刻み(秒)の候補。
    static let steps: [Double] = [0.1, 0.25, 0.5, 1, 2, 5, 10, 30, 60]
    public static let maxTiles = 4000

    /// クリップの絵の幅(pt)と 1 枚の幅から、並べる枚数。
    public static func tileCount(width: Double, tileWidth: Double) -> Int {
        guard width > 0, tileWidth > 0 else { return 0 }
        return min(maxTiles, max(1, Int((width / tileWidth).rounded(.up))))
    }

    /// 1 枚が受け持つ素材の長さ(秒)に合わせた丸めの刻み。
    static func step(forTileSpan span: Double) -> Double {
        steps.last { $0 <= span } ?? steps[0]
    }

    /// 左から i 番目(全 n 枚)のタイルの素材の時刻。タイルの真ん中の時刻を刻みに切り下げる(素材の終わりより先へは行かない)。
    /// 逆再生は右のタイルほど素材の頭に近い。素材の範囲 [offset, offset + 使う長さ] の外へは出さない。フリーズは頭のコマだけ。
    public static func time(for c: Clip, tile i: Int, of n: Int) -> Double {
        if c.isFreeze { return c.offset }
        let r = WaveformPeaks.sourceRange(for: c)
        let lo = min(r.from, r.to), hi = max(r.from, r.to)
        guard n > 0 else { return lo }
        let step = step(forTileSpan: (hi - lo) / Double(n))
        let f = (Double(min(max(0, i), n - 1)) + 0.5) / Double(n)
        let t = r.from + (r.to - r.from) * f
        return min(max((t / step).rounded(.down) * step, lo), hi)
    }

    /// 全タイルの素材の時刻(左から)。
    public static func times(for c: Clip, tiles n: Int) -> [Double] {
        n > 0 ? (0..<n).map { time(for: c, tile: $0, of: n) } : []
    }
}
