import Foundation
import CoreGraphics
import ImageIO
import AVFoundation

/// 描画に使う素材のキャッシュ(画像・動画フレーム・口パク用の音量エンベロープ)。
/// 読めないファイルは nil を返すだけで、クラッシュしない。スレッドセーフ。
public final class RenderAssets {
    private let lock = NSLock()
    private var images: [String: CGImage] = [:]
    private var missingImages: Set<String> = []
    private var envelopes: [String: [Float]] = [:]
    private var missingEnvelopes: Set<String> = []
    private var generators: [String: AVAssetImageGenerator] = [:]
    private var missingVideos: Set<String> = []
    private var exportMode = false
    private var sequentials: [String: SequentialVideoFrames] = [:]

    public init() {}

    /// 画像(ImageIO)。パスをキーにキャッシュする。
    public func image(at path: String) -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        if let i = images[path] { return i }
        if missingImages.contains(path) { return nil }
        let url = URL(fileURLWithPath: path)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            missingImages.insert(path)
            return nil
        }
        images[path] = img
        return img
    }

    /// 口パク用のエンベロープ: チャンネル 0 の 1/60 秒ごとの RMS(renderer.js getBuffer と同じ)。
    public func mouthEnvelope(for path: String) -> [Float]? {
        lock.lock(); defer { lock.unlock() }
        if let e = envelopes[path] { return e }
        if missingEnvelopes.contains(path) { return nil }
        guard let env = Self.computeEnvelope(path) else {
            missingEnvelopes.insert(path)
            return nil
        }
        envelopes[path] = env
        return env
    }

    static func computeEnvelope(_ path: String) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { return nil }
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames),
              (try? file.read(into: buf)) != nil,
              let ch = buf.floatChannelData else { return nil }
        let n = Int(buf.frameLength)
        let step = max(1, Int(file.processingFormat.sampleRate / 60))
        let data = ch[0]
        var env = [Float](repeating: 0, count: (n + step - 1) / step)
        for i in 0..<env.count {
            var sum: Float = 0
            let s = i * step, e = min(n, s + step)
            var j = s
            while j < e { sum += data[j] * data[j]; j += 1 }
            env[i] = (sum / Float(step)).squareRoot()
        }
        return env
    }

    /// 書き出しモード: 動画フレームを AVAssetReader で前から順に読む(時刻が戻ったときだけ generator)。
    public func beginExportMode() {
        lock.lock(); exportMode = true; lock.unlock()
    }

    /// 書き出しモードを終えて、読み取り用のリソースを手放す。
    public func endExportMode() {
        lock.lock()
        exportMode = false
        let seqs = sequentials
        sequentials = [:]
        lock.unlock()
        seqs.values.forEach { $0.close() }
    }

    /// 動画の time 秒のフレーム。通常はパスごとに generator、書き出しモードでは順次読み。
    public func videoFrame(path: String, time: Double) -> CGImage? {
        lock.lock()
        if exportMode, !missingVideos.contains(path) {
            var seq = sequentials[path]
            if seq == nil {
                seq = SequentialVideoFrames(url: URL(fileURLWithPath: path)) { [unowned self] t in self.generatorFrame(path: path, time: t) }
                sequentials[path] = seq
            }
            lock.unlock()
            return seq?.frame(at: time)
        }
        lock.unlock()
        return generatorFrame(path: path, time: time)
    }

    /// AVAssetImageGenerator で任意時刻のフレームを取る(正確・低速)。
    func generatorFrame(path: String, time: Double) -> CGImage? {
        lock.lock()
        if missingVideos.contains(path) { lock.unlock(); return nil }
        var gen = generators[path]
        if gen == nil {
            let g = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: path)))
            g.appliesPreferredTrackTransform = true
            let tol = CMTime(value: 1, timescale: 120)
            g.requestedTimeToleranceBefore = tol
            g.requestedTimeToleranceAfter = tol
            generators[path] = g
            gen = g
        }
        lock.unlock()
        guard let g = gen else { return nil }
        let t = CMTime(seconds: max(0, time), preferredTimescale: 600)
        if let img = try? g.copyCGImage(at: t, actualTime: nil) { return img }
        lock.lock(); missingVideos.insert(path); lock.unlock()
        return nil
    }
}
