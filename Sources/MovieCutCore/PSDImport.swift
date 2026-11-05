import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// PSD の取り込み方。
public enum PSDImportMode: Equatable, Sendable {
    /// 見えるレイヤーを 1 枚ずつ別のクリップにする
    case layers
    /// 統合した 1 枚にする
    case flattened
}

/// 取り込みで置く 1 枚(PNG に書き出したもの)と、キャンバス上の配置。
public struct PSDImportItem: Equatable, Sendable {
    public var path: String
    public var name: String
    public var scale: Double
    public var x: Double
    public var y: Double
    public var opacity: Double
}

public struct PSDImportPlan: Equatable, Sendable {
    /// 下のレイヤーが先
    public var items: [PSDImportItem]
    /// 非表示(グループの目も含む)で読み込まなかった実レイヤーの数
    public var hiddenSkipped: Int
    /// 大きさが 0 で読み込まなかったレイヤーの数
    public var emptySkipped: Int
    /// レイヤーを使えず、統合済みの画像で代用した
    public var usedComposite: Bool
}

public enum PSDImporter {
    public static func isPSD(path: String) -> Bool {
        (path as NSString).pathExtension.lowercased() == "psd"
    }

    /// 書き出し先フォルダの名前: パス + 更新日時 + サイズ から決まる(同じファイルなら同じ、変わったら別)。
    public static func cacheKey(path: String, modified: Date?, size: Int64?) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        let s = "\(path)|\(modified?.timeIntervalSince1970 ?? 0)|\(size ?? 0)"
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return String(format: "%016llx", h)
    }

    /// PSD のキャンバス (pw × ph) を、プロジェクトのキャンバス (W × H) に収まるよう一様に拡大縮小して中央に置いたとき、
    /// 範囲 (left, top, lw × lh) の画像クリップの (x, y, scale)。画像クリップは「W×H に収まる大きさ × scale」で描かれる。
    public static func geometry(left: Int, top: Int, width lw: Int, height lh: Int, psdWidth pw: Int, psdHeight ph: Int,
                                canvasWidth cw: Int, canvasHeight ch: Int) -> (x: Double, y: Double, scale: Double) {
        let W = Double(cw), H = Double(ch)
        let s = min(W / Double(pw), H / Double(ph))
        if lw == pw, lh == ph, left == 0, top == 0 { return (0.5, 0.5, 1) }
        let fit = min(W / Double(lw), H / Double(lh))
        let scale = s / fit
        let cx = (W - Double(pw) * s) / 2 + (Double(left) + Double(lw) / 2) * s
        let cy = (H - Double(ph) * s) / 2 + (Double(top) + Double(lh) / 2) * s
        return (cx / W, cy / H, scale)
    }

    /// PNG を `cacheDir` に書き出して、置くものの一覧を作る。すでにあるファイルは作り直さない。
    public static func prepare(_ doc: PSDDocument, mode: PSDImportMode, canvasWidth: Int, canvasHeight: Int,
                               cacheDir: URL) throws -> PSDImportPlan {
        let fm = FileManager.default
        try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        var items: [PSDImportItem] = []
        var hidden = 0, empty = 0
        var usedComposite = false

        func compositeItem() throws -> PSDImportItem? {
            guard let raster = doc.composite ?? flatten(doc) else { return nil }
            let url = cacheDir.appendingPathComponent("merged.png")
            try writePNGIfNeeded(raster, to: url)
            return PSDImportItem(path: url.path, name: "PSD", scale: 1, x: 0.5, y: 0.5, opacity: 1)
        }

        let content = doc.contentLayers
        if mode == .flattened || content.isEmpty {
            // 統合 1 枚(レイヤーが 1 枚も読めなかったときも、これで代用する)
            if let it = try compositeItem() { items = [it] }
            usedComposite = mode == .layers
            if mode == .flattened { hidden = content.filter { !$0.effectivelyVisible }.count }
        } else {
            for (i, layer) in doc.layers.enumerated() where !layer.isGroupMarker {
                if !layer.effectivelyVisible { hidden += 1; continue }
                if layer.raster.isEmpty { empty += 1; continue }
                let url = cacheDir.appendingPathComponent("layer-\(i).png")
                try writePNGIfNeeded(layer.raster, to: url)
                let g = geometry(left: layer.left, top: layer.top, width: layer.width, height: layer.height,
                                 psdWidth: doc.width, psdHeight: doc.height, canvasWidth: canvasWidth, canvasHeight: canvasHeight)
                items.append(PSDImportItem(path: url.path, name: layer.name, scale: g.scale, x: g.x, y: g.y,
                                           opacity: Double(layer.opacity) / 255))
            }
        }
        return PSDImportPlan(items: items, hiddenSkipped: hidden, emptySkipped: empty, usedComposite: usedComposite)
    }

    /// レイヤーを通常の重ね方(不透明度のみ)で 1 枚にする。統合済みの画像が無いときの代わり。
    public static func flatten(_ doc: PSDDocument) -> PSDRaster? {
        guard let ctx = CGContext(data: nil, width: doc.width, height: doc.height, bitsPerComponent: 8, bytesPerRow: doc.width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        for layer in doc.layers where !layer.isGroupMarker && layer.effectivelyVisible && !layer.raster.isEmpty {
            guard let img = cgImage(layer.raster) else { continue }
            ctx.setAlpha(CGFloat(layer.opacity) / 255)
            // CGContext は左下原点
            ctx.draw(img, in: CGRect(x: layer.left, y: doc.height - layer.top - layer.height, width: layer.width, height: layer.height))
        }
        guard let out = ctx.makeImage() else { return nil }
        return raster(out)
    }

    // MARK: PNG

    static func cgImage(_ r: PSDRaster) -> CGImage? {
        guard !r.isEmpty, r.rgba.count >= r.width * r.height * 4 else { return nil }
        var px = r.rgba
        var i = 0
        while i < px.count {   // プリマルチプライドにする
            let a = UInt32(px[i + 3])
            if a != 255 {
                px[i] = UInt8((UInt32(px[i]) * a + 127) / 255)
                px[i + 1] = UInt8((UInt32(px[i + 1]) * a + 127) / 255)
                px[i + 2] = UInt8((UInt32(px[i + 2]) * a + 127) / 255)
            }
            i += 4
        }
        guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: r.width, height: r.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: r.width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// プリマルチプライドの CGImage から非プリマルチプライドの画素へ(統合の結果を戻す)。
    static func raster(_ img: CGImage) -> PSDRaster? {
        let w = img.width, h = img.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        var i = 0
        while i < px.count {
            let a = UInt32(px[i + 3])
            if a != 0, a != 255 {
                px[i] = UInt8(min(255, (UInt32(px[i]) * 255 + a / 2) / a))
                px[i + 1] = UInt8(min(255, (UInt32(px[i + 1]) * 255 + a / 2) / a))
                px[i + 2] = UInt8(min(255, (UInt32(px[i + 2]) * 255 + a / 2) / a))
            }
            i += 4
        }
        return PSDRaster(width: w, height: h, rgba: px)
    }

    public static func pngData(_ r: PSDRaster) -> Data? {
        guard let img = cgImage(r) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    private static func writePNGIfNeeded(_ r: PSDRaster, to url: URL) throws {
        let fm = FileManager.default
        if let a = try? fm.attributesOfItem(atPath: url.path), (a[.size] as? NSNumber)?.intValue ?? 0 > 0 { return }
        guard let data = pngData(r) else { throw PSDError.corrupt("PNG を作れません") }
        try data.write(to: url, options: .atomic)
    }

    // MARK: 置く

    /// `start` から `duration` 秒、見えるレイヤーを 1 枚ずつ別のレイヤー(タイムラインの段)に置く。
    /// PSD の下のレイヤーほど下の段(番号が小さい = 下に描く)。すでにある段は、その区間が空いていて、
    /// 前の PSD レイヤーより上にあるものだけ使い、足りなければ新しい段を足す。置いたクリップの id を下から順に返す。
    public static func place(_ items: [PSDImportItem], at start: Double, duration: Double = ClipEditing.defaultMediaDuration,
                             in project: inout Project) -> [String] {
        var ids: [String] = []
        var minIndex = 0
        for it in items {
            var ti: Int? = nil
            var i = minIndex
            while i < project.tracks.count {
                if ClipEditing.isFree(project, track: i, start: start, duration: duration) { ti = i; break }
                i += 1
            }
            if ti == nil {
                project.tracks.append(Track(name: "レイヤー\(project.tracks.count + 1)"))
                ti = project.tracks.count - 1
            }
            var c = ClipEditing.makeMediaClip(path: it.path, kind: .image, duration: duration, start: start)
            c.x = it.x; c.y = it.y; c.scale = it.scale; c.opacity = it.opacity
            project.tracks[ti!].clips.append(c)
            ids.append(c.id)
            minIndex = ti! + 1
        }
        return ids
    }
}

public extension ClipEditing {
    /// タイムラインや「素材を追加」で受け付けるか(素材として置けるもの + PSD)。
    static func isDroppableMedia(path: String) -> Bool {
        isSupportedMedia(path: path) || PSDImporter.isPSD(path: path)
    }
}
