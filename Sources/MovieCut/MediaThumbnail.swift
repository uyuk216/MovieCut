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
