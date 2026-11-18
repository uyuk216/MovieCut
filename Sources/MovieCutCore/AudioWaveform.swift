import Foundation
import AVFoundation

// MARK: - 音声波形(素材ブラウザのサムネイル波形・X-2)
//
// 音声素材の波形(バケットごとの最小値・最大値)を、素材ファイルから作る。
// - 生成はストリーミング(少しずつ読んでバケットへ集計)なので、長い音声でも
//   全サンプルをメモリに載せない。
// - キャッシュはメモリだけ(`CacheBudgetManager` 配下。ディスクには書かない)。
//   予算を超えたら LRU で破棄される。素材ファイル自体の読み込み以外に
//   ファイル書き込みは一切しない。
// - サンプル列から波形を作る部分は純粋関数で、単体テストできる。

/// 波形データ: バケットごとの最小値・最大値(どちらも -1〜1)。
public struct AudioWaveformData: Equatable, Sendable {
    public var minimums: [Float]
    public var maximums: [Float]
    /// 音声の長さ(秒)。
    public var duration: Double

    public init(minimums: [Float], maximums: [Float], duration: Double) {
        let n = min(minimums.count, maximums.count)
        self.minimums = Array(minimums.prefix(n))
        self.maximums = Array(maximums.prefix(n))
        self.duration = duration
    }

    /// バケット数。
    public var bucketCount: Int { minimums.count }

    /// バケットごとのピーク(絶対値の大きい方、0〜1)。
    public var peaks: [Float] {
        (0..<bucketCount).map { max(abs(minimums[$0]), abs(maximums[$0])) }
    }

    /// キャッシュのバイトコスト見積もり(最小・最大の Float 列 + 固定分)。
    public var byteCost: Int { bucketCount * 8 + 64 }

    /// 表示用に `count` 本のバーの高さ(0〜1)へリサンプルする。
    /// バケットの方が多ければ最大プーリング、少なければ最近傍で引き伸ばす。
    public func barHeights(count: Int) -> [Float] {
        guard count > 0 else { return [] }
        let p = peaks
        guard !p.isEmpty else { return [Float](repeating: 0, count: count) }
        if count == p.count { return p }
        if count > p.count {
            return (0..<count).map { p[min(p.count - 1, $0 * p.count / count)] }
        }
        return (0..<count).map { bar in
            let lo = bar * p.count / count
            let hi = max(lo + 1, (bar + 1) * p.count / count)
            var m: Float = 0
            for i in lo..<min(hi, p.count) { m = max(m, p[i]) }
            return m
        }
    }
}

/// サンプルを少しずつ流し込んで波形へ集計する(総フレーム数が先に分かる場合用)。
public struct WaveformAccumulator: Sendable {
    public let totalFrames: Int
    public let bucketCount: Int
    private var minimums: [Float]
    private var maximums: [Float]
    private var appended: Int = 0

    public init(totalFrames: Int, bucketCount: Int) {
        self.totalFrames = max(0, totalFrames)
        self.bucketCount = max(1, bucketCount)
        self.minimums = [Float](repeating: 0, count: self.bucketCount)
        self.maximums = [Float](repeating: 0, count: self.bucketCount)
    }

    /// モノラルサンプルを追加する(総数を超えた分は最後のバケットへ丸める)。
    public mutating func append(mono samples: [Float]) {
        guard totalFrames > 0 else {
            // 総数が分からない(0)ときは集計できない。呼び出し側は総数を渡すこと。
            appended += samples.count
            return
        }
        for s in samples {
            let frame = appended
            let bucket = min(bucketCount - 1, Int(Int64(frame) * Int64(bucketCount) / Int64(totalFrames)))
            if s < minimums[bucket] { minimums[bucket] = s }
            if s > maximums[bucket] { maximums[bucket] = s }
            appended += 1
        }
    }

    /// 集計結果。`duration` は呼び出し側が知っている長さ(秒)。
    public func finish(duration: Double) -> AudioWaveformData {
        AudioWaveformData(minimums: minimums, maximums: maximums, duration: duration)
    }
}

/// 波形の生成(純粋な集計 + ファイルからの読み込み)。
public enum AudioWaveform {
    /// 既定のバケット数(サムネイル・プレビュー表示に十分な細かさ)。
    public static let defaultBucketCount = 240
    /// 読み込みのチャンク(フレーム数)。
    static let chunkFrames = 16_384

    /// モノラルサンプル列から波形を作る(純粋関数)。
    public static func waveform(mono samples: [Float], bucketCount: Int, duration: Double) -> AudioWaveformData {
        var acc = WaveformAccumulator(totalFrames: samples.count, bucketCount: bucketCount)
        acc.append(mono: samples)
        return acc.finish(duration: duration)
    }

    /// 複数チャンネルの平均でモノラル化する(純粋関数)。チャンネル長が違うときは最短に合わせる。
    public static func downmix(_ channels: [[Float]]) -> [Float] {
        guard let first = channels.first, !channels.isEmpty else { return [] }
        let n = channels.map(\.count).min() ?? 0
        guard n > 0 else { return [] }
        if channels.count == 1 { return first }
        let k = 1 / Float(channels.count)
        var out = [Float](repeating: 0, count: n)
        for ch in channels { for i in 0..<n { out[i] += ch[i] * k } }
        return out
    }

    /// キャッシュキー: パス + バケット数 + ファイルの大きさ・更新時刻(差し替えを検出するため)。
    public static func cacheKey(url: URL, bucketCount: Int) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? -1
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
        return "\(url.path)|\(bucketCount)|\(size)|\(mtime)"
    }

    /// 音声ファイルから波形を作る。読めない・音が無いファイルは nil。
    /// `AVAudioFile` で少しずつ読み、チャンネルは平均してモノラル化する。
    public static func generate(url: URL, bucketCount: Int = defaultBucketCount) async -> AudioWaveformData? {
        // 重い読み込みは呼び出し側のタスクをブロックしないよう detached で行う。
        await Task.detached(priority: .utility) { generateSync(url: url, bucketCount: bucketCount) }.value
    }

    /// `generate` の同期本体(テストからも直接呼べる)。
    public static func generateSync(url: URL, bucketCount: Int = defaultBucketCount) -> AudioWaveformData? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let total = Int(file.length)
        guard total > 0 else { return nil }
        let format = file.processingFormat
        let channels = max(1, Int(format.channelCount))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunkFrames)) else { return nil }
        var acc = WaveformAccumulator(totalFrames: total, bucketCount: bucketCount)
        var mono: [Float] = []
        mono.reserveCapacity(chunkFrames)
        while file.framePosition < file.length {
            do { try file.read(into: buffer, frameCount: AVAudioFrameCount(chunkFrames)) } catch { return nil }
            let frames = Int(buffer.frameLength)
            guard frames > 0, let data = buffer.floatChannelData else { break }
            mono.removeAll(keepingCapacity: true)
            if channels == 1 {
                mono.append(contentsOf: UnsafeBufferPointer(start: data[0], count: frames))
            } else {
                mono = [Float](repeating: 0, count: frames)
                let k = 1 / Float(channels)
                for c in 0..<channels {
                    let src = data[c]
                    for i in 0..<frames { mono[i] += src[i] * k }
                }
            }
            acc.append(mono: mono)
            if frames < chunkFrames { break }
        }
        let duration = Double(total) / format.sampleRate
        return acc.finish(duration: duration)
    }
}

/// 波形のメモリキャッシュ。`CacheBudgetManager` 配下で LRU 破棄され、ディスクには書かない。
public final class WaveformCache: @unchecked Sendable {
    /// アプリ全体で共有するキャッシュ(メモリ予算はこのマシンの作業メモリ上限から決める)。
    public static let shared = WaveformCache(budget: CacheBudgetManager(limitBytes: MemoryBudget.currentLimitBytes(platform: .mac)))

    private let lock = NSLock()
    private var store: [String: AudioWaveformData] = [:]
    public let budget: CacheBudgetManager?

    public init(budget: CacheBudgetManager?) {
        self.budget = budget
    }

    /// 登録中の件数(テスト・診断用)。
    public var count: Int { lock.lock(); defer { lock.unlock() }; return store.count }

    /// キーで引く(あれば予算マネージャへ「使った」と知らせる)。
    public func cached(key: String) -> AudioWaveformData? {
        lock.lock()
        let value = store[key]
        lock.unlock()
        if value != nil { budget?.touch("waveform|" + key) }
        return value
    }

    /// 覚える。予算を超えると LRU で古いものから破棄される(破棄で実体も消える)。
    public func store(_ data: AudioWaveformData, key: String) {
        lock.lock(); store[key] = data; lock.unlock()
        budget?.register(key: "waveform|" + key, cost: Int64(data.byteCost)) { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.store[key] = nil; self.lock.unlock()
        }
    }

    /// 全て忘れる(メモリ逼迫時など)。
    public func purge() {
        lock.lock(); store.removeAll(); lock.unlock()
        budget?.purgeAll()
    }

    /// URL の波形: キャッシュにあればそれ、無ければ作って覚える。作れなければ nil。
    public func waveform(url: URL, bucketCount: Int = AudioWaveform.defaultBucketCount) async -> AudioWaveformData? {
        let key = AudioWaveform.cacheKey(url: url, bucketCount: bucketCount)
        if let hit = cached(key: key) { return hit }
        guard let data = await AudioWaveform.generate(url: url, bucketCount: bucketCount) else { return nil }
        store(data, key: key)
        return data
    }
}
