import SwiftUI
import AppKit
import AVFoundation
import MovieCutCore

/// 素材ブラウザのサムネイル。動画は先頭付近の 1 コマ、画像は読み込み、音声は絵を持たない(種類のアイコンを出す)。
/// 作れたものはメモリに覚える(NSCache。ディスクには書かない)。
@MainActor
enum MediaThumbnail {
    private static let cache = NSCache<NSString, NSImage>()

    static func load(_ item: MediaBrowser.Item, maxSide: CGFloat) async -> NSImage? {
        let key = "\(item.url.path)#\(Int(maxSide))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        var image: NSImage?
        switch item.kind {
        case .image:
            image = NSImage(contentsOf: item.url)
        case .video:
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: item.url))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: maxSide * 2, height: maxSide * 2)
            if let r = try? await gen.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)) {
                image = NSImage(cgImage: r.image, size: .zero)
            }
        case .audio:
            // 音声は波形をサムネイルにする(X-2)。波形はメモリキャッシュ経由(ディスクに書かない)。
            if let wf = await WaveformCache.shared.waveform(url: item.url, bucketCount: 120) {
                image = WaveformThumbnailRenderer.image(peaks: wf.peaks, width: maxSide * 2, height: maxSide)
            }
        default:
            image = nil
        }
        if let image { cache.setObject(image, forKey: key) }
        return image
    }

    static func symbol(for kind: ClipType) -> String {
        switch kind {
        case .video: return "film"
        case .audio: return "waveform"
        case .image: return "photo"
        default: return "doc"
        }
    }
}

/// 一行・一コマ分のサムネイル表示。絵が無いときは種類のアイコン。
struct MediaThumbnailView: View {
    let item: MediaBrowser.Item
    let width: CGFloat
    let height: CGFloat
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15))
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: MediaThumbnail.symbol(for: item.kind))
                    .font(.system(size: min(width, height) * 0.4))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task(id: item.id) { image = await MediaThumbnail.load(item, maxSide: max(width, height)) }
    }
}

/// 波形のサムネイル画像(ピーク列 → 中央寄せのバーのビットマップ)。色は固定の青灰色。
enum WaveformThumbnailRenderer {
    static func image(peaks: [Float], width: CGFloat, height: CGFloat) -> NSImage? {
        let w = max(8, Int(width.rounded())), h = max(8, Int(height.rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let data = AudioWaveformData(minimums: peaks.map { -$0 }, maximums: peaks, duration: 0)
        let bars = max(1, w / 3)
        let heights = data.barHeights(count: bars)
        let barW = Double(w) / Double(bars)
        ctx.setFillColor(CGColor(srgbRed: 0.30, green: 0.52, blue: 0.92, alpha: 1))
        for i in 0..<bars {
            let bh = max(1.0, Double(heights[i]) * Double(h) * 0.92)
            ctx.fill(CGRect(x: Double(i) * barW + barW * 0.2, y: (Double(h) - bh) / 2,
                            width: max(1.0, barW * 0.6), height: bh))
        }
        guard let cg = ctx.makeImage() else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: w, height: h))
    }
}

/// 素材プレビュー用の波形表示(音声のみ)。読み込み中はプログレス、作れないときはアイコン。
struct AudioWaveformView: View {
    let item: MediaBrowser.Item
    var height: CGFloat = 64
    @State private var waveform: AudioWaveformData?
    @State private var failed = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12))
            if let wf = waveform {
                Canvas { ctx, size in
                    let bars = max(8, Int(size.width / 4))
                    let hs = wf.barHeights(count: bars)
                    let bw = size.width / CGFloat(bars)
                    for (i, v) in hs.enumerated() {
                        let bh = max(1, CGFloat(v) * size.height * 0.92)
                        let rect = CGRect(x: CGFloat(i) * bw + bw * 0.2, y: (size.height - bh) / 2,
                                          width: max(1, bw * 0.6), height: bh)
                        ctx.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(.accentColor))
                    }
                }
            } else if failed {
                Image(systemName: "waveform").font(.title3).foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(height: height)
        .task(id: item.id) {
            waveform = nil; failed = false
            if let wf = await WaveformCache.shared.waveform(url: item.url, bucketCount: 240) {
                waveform = wf
            } else {
                failed = true
            }
        }
    }
}
