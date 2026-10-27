import Foundation
import CoreGraphics
import AVFoundation
import VideoToolbox

/// 書き出し中に、逆再生する動画クリップのフレームを後ろから前へ取り出す(AVAssetReader, BGRA)。
///
/// 逆向きに直接は読めないので、「いま要る時刻の少し前までの区間」を丸ごと読んで、メモリの束(チャンク)に置く。
/// - 束は **最大 `maxFramesLimit`(240)コマ・最大 `byteBudget`(既定 384 MB。環境変数 `MC_REVERSE_CACHE_MB` で変更可)** まで。
///   束は「いま使っている束」と「次(一つ前の区間)を先読みしている束」の 2 つなので、1 つに使えるのは予算の半分。
/// - 先読み: いまの束の後ろ半分に入ったら、その前の区間を別スレッドで読み始める(描画・エンコードと復号が重なるので、逆再生でも書き出しが遅くなりにくい)。
/// - 1 つの束の読み込みは直前のキーフレームから復号するので、GOP が長い素材では同じコマを少し余計に復号する。
/// 回転情報がある素材・読み込みに失敗した素材は `fallback`(AVAssetImageGenerator)で 1 コマずつ取る(正確・低速)。
final class ReverseVideoFrames {
    /// 1 つの束に置くコマ数の上限と、メモリの目安(画素 4 バイト × 大きさ × コマ数)。
    static let maxFramesLimit = 240
    static let defaultByteBudget = 384 * 1024 * 1024
    static var byteBudget: Int {
        if let s = ProcessInfo.processInfo.environment["MC_REVERSE_CACHE_MB"], let mb = Int(s), mb >= 16 { return mb * 1024 * 1024 }
        return defaultByteBudget
    }

    typealias Chunk = [(pts: Double, img: CGImage)]

    /// 先読み中の束(別スレッドが `result` を入れる)。
    private final class Prefetch {
        let end: Double
        let group = DispatchGroup()
        var result: Chunk = []
        init(end: Double) { self.end = end }
    }

    private let asset: AVURLAsset
    private let track: AVAssetTrack?
    private let needsTransform: Bool
    private let totalDuration: Double
    private let fallback: (Double) -> CGImage?
    private let frameDuration: Double
    private let chunkFrames: Int
    private let queue = DispatchQueue(label: "moviecut.reverse.prefetch", qos: .userInitiated)
    private var frames: Chunk = []
    private var coverEnd = -Double.infinity     // 束がカバーする区間の終わり(この時刻以下の最後のコマが束の中にある)
    private var prefetch: Prefetch?
    private var broken = false
    private let lock = NSLock()
    /// 検証用: 読み込みを何回したか(先読みも数える)と、先読みで間に合った回数。
    private(set) var chunkLoads = 0
    private(set) var prefetchHits = 0

    init(url: URL, byteBudget: Int = ReverseVideoFrames.byteBudget, fallback: @escaping (Double) -> CGImage?) {
        asset = AVURLAsset(url: url)
        track = asset.tracks(withMediaType: .video).first
        let t = track?.preferredTransform ?? .identity
        needsTransform = !(t.a == 1 && t.b == 0 && t.c == 0 && t.d == 1)
        totalDuration = asset.duration.seconds
        self.fallback = fallback
        var fps = Double(track?.nominalFrameRate ?? 0)
        if !(fps > 1 && fps < 1000) { fps = 30 }
        frameDuration = 1 / fps
        let size = track?.naturalSize ?? CGSize(width: 1920, height: 1080)
        let bytes = max(1, Int(size.width * size.height * 4))
        chunkFrames = min(Self.maxFramesLimit, max(8, byteBudget / bytes / 2))
    }

    /// 束に置けるコマ数の上限(検証用)。
    var capacityFrames: Int { chunkFrames }
    /// いま束にあるコマ数(検証用)。
    var loadedFrames: Int { lock.lock(); defer { lock.unlock() }; return frames.count }

    func frame(at time: Double) -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        let t = totalDuration.isFinite && totalDuration > 0 ? min(max(0, time), max(0, totalDuration - 0.002)) : max(0, time)
        if broken || track == nil || needsTransform { return fallback(t) }
        let probe = t + 0.001
        if let first = frames.first, probe >= first.pts, probe <= coverEnd, let hit = lookup(probe) {
            startPrefetchIfNeeded(first: first.pts, probe: probe)
            return hit
        }
        load(around: t)
        if broken { return fallback(t) }
        if let first = frames.first { startPrefetchIfNeeded(first: first.pts, probe: probe) }
        return lookup(probe) ?? frames.first?.img ?? fallback(t)
    }

    /// pts <= probe の最後のコマ(二分探索)。
    private func lookup(_ probe: Double) -> CGImage? {
        var lo = 0, hi = frames.count - 1, found = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if frames[mid].pts <= probe { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return found >= 0 ? frames[found].img : nil
    }

    private var chunkSeconds: Double { frameDuration * Double(chunkFrames) }

    /// 束の後ろ半分に入ったら、一つ前の区間を別スレッドで読み始める。
    private func startPrefetchIfNeeded(first: Double, probe: Double) {
        guard prefetch == nil, first > frameDuration, probe - first < chunkSeconds * 0.5 else { return }
        let p = Prefetch(end: first)
        prefetch = p
        chunkLoads += 1
        p.group.enter()
        queue.async { [self] in
            p.result = readChunk(end: p.end) ?? []
            p.group.leave()
        }
    }

    /// 時刻 t を含む束を用意する。先読みが一つ前の区間(t を含む)なら、それを待って使う。
    private func load(around t: Double) {
        if let p = prefetch {
            p.group.wait()
            prefetch = nil
            if t < p.end, !p.result.isEmpty, t >= p.result[0].pts - frameDuration {
                frames = p.result; coverEnd = p.end
                prefetchHits += 1
                return
            }
        }
        frames = []; coverEnd = -Double.infinity
        let end = t + frameDuration       // t を含むコマを確実に拾う
        chunkLoads += 1
        guard let list = readChunk(end: end) else { broken = true; return }
        frames = list
        coverEnd = end
    }

    /// [end − 束の長さ, end) のコマを読む。読めなければ nil。
    private func readChunk(end: Double) -> Chunk? {
        guard let track = track, let r = try? AVAssetReader(asset: asset) else { return nil }
        let o = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        o.alwaysCopiesSampleData = false
        guard r.canAdd(o) else { return nil }
        r.add(o)
        let start = max(0, end - chunkSeconds)
        // start の直前のコマ(start を含むコマ)も要るので、1 コマ半ぶん手前から
        let from = max(0, start - frameDuration * 1.5)
        r.timeRange = CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 600),
                                  duration: CMTime(seconds: max(0.05, end - from), preferredTimescale: 600))
        guard r.startReading() else { return nil }
        var list: Chunk = []
        while let sb = o.copyNextSampleBuffer() {
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sb).seconds
            if pts >= end { break }
            var img: CGImage?
            VTCreateCGImageFromCVPixelBuffer(pb, options: nil, imageOut: &img)
            if let img { list.append((pts, img)) }
            // 想定よりコマが細かい素材でも、メモリは上限のまま(古いほうを捨てる。必要なのは終わり側)
            if list.count > chunkFrames + 16 { list.removeFirst(16) }
        }
        r.cancelReading()
        if list.isEmpty { return nil }
        list.sort { $0.pts < $1.pts }
        return list
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        prefetch?.group.wait()
        prefetch = nil
        frames = []; coverEnd = -Double.infinity
    }
}
