import Foundation
import CoreGraphics
import AVFoundation
import VideoToolbox

/// 書き出し中に動画クリップのフレームを前から順に読む(AVAssetReader, BGRA)。
/// 最新のフレームを持ち続け、`frame(at:)` は時刻 t 以前で最後のフレームを返す。
/// 時刻が戻ったとき・回転情報があるときは fallback(AVAssetImageGenerator)で正しく返す。
final class SequentialVideoFrames {
    private let asset: AVURLAsset
    private let track: AVAssetTrack?
    private let needsTransform: Bool
    private let totalDuration: Double
    private let fallback: (Double) -> CGImage?
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var cur: (img: CGImage, pts: Double)?
    private var next: (img: CGImage, pts: Double)?
    private var broken = false
    private let lock = NSLock()
    /// 1 未満なら、読んだフレームをこの倍率に縮めて持つ(プレビュー再生のメモリ節約)。
    private let scale: Double

    init(url: URL, scale: Double = 1, fallback: @escaping (Double) -> CGImage?) {
        self.scale = scale
        asset = AVURLAsset(url: url)
        track = asset.tracks(withMediaType: .video).first
        let t = track?.preferredTransform ?? .identity
        needsTransform = !(t.a == 1 && t.b == 0 && t.c == 0 && t.d == 1)
        totalDuration = asset.duration.seconds
        self.fallback = fallback
    }

    func frame(at time: Double) -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        // 動画の終わりを越えたら最後のフレームを出し続ける(video 要素が終端で止まるのと同じ)
        let t = totalDuration.isFinite && totalDuration > 0 ? min(max(0, time), max(0, totalDuration - 0.002)) : max(0, time)
        if broken || track == nil || needsTransform { return fallback(t) }
        if let c = cur, t < c.pts - 0.0005 { return fallback(t) }  // 戻った
        let ahead = (next ?? cur).map { t > $0.pts + 1.0 } ?? true  // 大きく先へ飛んだ
        if reader == nil || ahead { restart(at: t) }
        if broken { return fallback(t) }
        while let n = next, n.pts <= t + 0.001 {
            cur = n
            next = readNext()
        }
        return cur?.img ?? fallback(t)
    }

    /// t の少し前から読み直す(t を含むフレームを確実に拾うため)。
    private func restart(at t: Double) {
        reader?.cancelReading()
        reader = nil; output = nil; cur = nil; next = nil
        guard let track = track, let r = try? AVAssetReader(asset: asset) else { broken = true; return }
        let o = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        o.alwaysCopiesSampleData = false
        guard r.canAdd(o) else { broken = true; return }
        r.add(o)
        let start = max(0, t - 0.25)
        let total = totalDuration
        r.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                  duration: CMTime(seconds: max(0.05, total - start), preferredTimescale: 600))
        guard r.startReading() else { broken = true; return }
        reader = r; output = o
        cur = readNext()
        next = readNext()
        if cur == nil { broken = true }
    }

    private func readNext() -> (img: CGImage, pts: Double)? {
        while let o = output, let sb = o.copyNextSampleBuffer() {
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            var img: CGImage?
            VTCreateCGImageFromCVPixelBuffer(pb, options: nil, imageOut: &img)
            if let img = img {
                let kept = scale < 1 ? Self.downscaled(img, scale: scale) : img
                return (kept, CMSampleBufferGetPresentationTimeStamp(sb).seconds)
            }
        }
        return nil
    }

    /// scale 倍(各辺最小 1px)に描き直した画像。作れなければ元の画像。
    static func downscaled(_ img: CGImage, scale: Double) -> CGImage {
        let w = max(1, Int((Double(img.width) * scale).rounded()))
        let h = max(1, Int((Double(img.height) * scale).rounded()))
        guard w < img.width || h < img.height,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: img.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
                ?? CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                             space: CGColorSpaceCreateDeviceRGB(),
                             bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return img }
        ctx.interpolationQuality = .medium
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? img
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        reader?.cancelReading()
        reader = nil; output = nil; cur = nil; next = nil
    }
}
