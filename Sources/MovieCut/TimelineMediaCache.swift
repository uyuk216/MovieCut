import Foundation
import AppKit
import AVFoundation
import ImageIO
import MovieCutCore

/// A6: タイムラインのサムネイルと波形のメモリ上のキャッシュ(ディスクには書かない)。
/// 描画は同期で「あれば返す・無ければ nil」。無いものは裏で作り(数を絞り、新しい依頼が先)、できたら通知で描き直させる。
/// キーは パス + 更新日時 (+ 時刻) なので、素材ファイルが差し替わると別のものとして作り直す。UI を止めない。
@MainActor
final class TimelineMediaCache {
    static let shared = TimelineMediaCache()
    static let didLoad = Notification.Name("MovieCutTimelineMediaDidLoad")

    /// 波形の入れ物(音が無い素材は peaks が nil で「無い」と覚える)。
    final class WaveBox { let peaks: WaveformPeaks?; init(_ p: WaveformPeaks?) { peaks = p } }

    private let thumbs = NSCache<NSString, CGImage>()
    private let waves = NSCache<NSString, WaveBox>()
    private var pending = Set<String>()
    private var queue: [String] = []                // 後ろ = 新しい依頼(先に作る)
    private var jobs: [String: () async -> Void] = [:]
    private var running = 0
    private var failed = Set<String>()
    private var mtimeCache: [String: (date: Double, checked: CFTimeInterval)] = [:]
    private var notifyScheduled = false
    /// 同時に作る数と、待たせる数の上限(スクロールで依頼があふれたら古いものを捨てる)。
    static let maxRunning = 2
    static let maxQueued = 160
    /// 作れなかったものの覚え(再試行しないためのもの)の上限。これを超えたら覚えを作り直す(失敗したものは次に開いたとき、もう一度試すだけ)。
    static let maxFailed = 2000

    init() {
        thumbs.countLimit = 600
        waves.countLimit = 80
    }

    // MARK: キー

    /// 素材ファイルの更新日時(秒)。stat は 5 秒に 1 回だけ(描画のたびに呼ばれるので)。
    func fileStamp(_ path: String) -> Double {
        let now = CACurrentMediaTime()
        if let c = mtimeCache[path], now - c.checked < 5 { return c.date }
        let d = ((try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date)?.timeIntervalSinceReferenceDate ?? -1
        mtimeCache[path] = (d, now)
        return d
    }

    static func thumbKey(path: String, stamp: Double, time: Double) -> String {
        "\(path)|\(Int(stamp))|\(Int((time * 1000).rounded()))"
    }

    // MARK: サムネイル

    /// その時刻のサムネイル(画像なら time は無視)。まだ無ければ nil を返し、裏で作る。
    func thumbnail(path: String, time: Double, isImage: Bool) -> CGImage? {
        let stamp = fileStamp(path)
        let key = Self.thumbKey(path: path, stamp: stamp, time: isImage ? 0 : time)
        if let img = thumbs.object(forKey: key as NSString) { return img }
        guard !failed.contains(key) else { return nil }
        enqueue(key) { [weak self] in
            let image: CGImage? = isImage ? Self.loadStill(path: path) : await Self.generate(path: path, time: time)
            await MainActor.run { self?.finishThumb(key: key, image: image) }
        }
        return nil
    }

    private func finishThumb(key: String, image: CGImage?) {
        if let image { thumbs.setObject(image, forKey: key as NSString) } else { recordFailure(key) }
        finish(key)
    }

    /// 作れなかったキーを覚える(上限を超えたら覚えを空にする)。
    func recordFailure(_ key: String) {
        if failed.count >= Self.maxFailed { failed.removeAll() }
        failed.insert(key)
    }

    /// 作れなかったものの覚えの数(テスト用)。
    var failedCount: Int { failed.count }

    nonisolated static func loadStill(path: String) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 256,
        ] as CFDictionary)
    }

    nonisolated static func generate(path: String, time: Double) async -> CGImage? {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let g = AVAssetImageGenerator(asset: asset)
        g.appliesPreferredTrackTransform = true
        g.maximumSize = CGSize(width: 256, height: 256)
        // 近い位置のコマで足りる(速く出る)
        g.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        g.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        return try? await g.image(at: CMTime(seconds: max(0, time), preferredTimescale: 600)).image
    }

    // MARK: 波形

    /// 波形のピーク。まだ読めていなければ nil(裏で読む)。音が無い・読めない素材は `hasNoAudio` が true になる。
    func waveform(path: String) -> WaveformPeaks? {
        waveBox(path: path)?.peaks
    }

    /// 読み終えたが音が無い(または読めなかった)素材か。
    func hasNoAudio(path: String) -> Bool {
        if let b = waveBox(path: path) { return b.peaks == nil }
        return false
    }

    private func waveBox(path: String) -> WaveBox? {
        let key = "wave|\(path)|\(Int(fileStamp(path)))"
        if let b = waves.object(forKey: key as NSString) { return b }
        enqueue(key) { [weak self] in
            let p = await WaveformPeaks.load(url: URL(fileURLWithPath: path))
            await MainActor.run {
                self?.waves.setObject(WaveBox(p), forKey: key as NSString)
                self?.finish(key)
            }
        }
        return nil
    }

    // MARK: 依頼の順番待ち

    private func enqueue(_ key: String, _ job: @escaping () async -> Void) {
        guard !pending.contains(key) else { return }
        pending.insert(key)
        jobs[key] = job
        queue.append(key)
        if queue.count > Self.maxQueued {
            let drop = queue.removeFirst()
            pending.remove(drop); jobs[drop] = nil
        }
        pump()
    }

    private func pump() {
        while running < Self.maxRunning, let key = queue.popLast(), let job = jobs.removeValue(forKey: key) {
            running += 1
            Task.detached(priority: .utility) { await job() }
        }
    }

    private func finish(_ key: String) {
        pending.remove(key)
        running = max(0, running - 1)
        pump()
        scheduleNotify()
    }

    /// できたものをまとめて 1 回で知らせる(0.1 秒ごと)。
    private func scheduleNotify() {
        guard !notifyScheduled else { return }
        notifyScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            MainActor.assumeIsolated {
                self?.notifyScheduled = false
                NotificationCenter.default.post(name: Self.didLoad, object: nil)
            }
        }
    }

    // MARK: 検証用

    /// 依頼が全部終わるまで待つ(テスト用)。
    func waitUntilIdle(timeout: TimeInterval = 10) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while (!pending.isEmpty || running > 0) && Date() < end { try? await Task.sleep(nanoseconds: 20_000_000) }
        return pending.isEmpty && running == 0
    }

    func removeAll() {
        thumbs.removeAllObjects(); waves.removeAllObjects(); failed.removeAll(); mtimeCache.removeAll()
    }
}
