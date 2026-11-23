import Foundation
import CoreGraphics
import CoreImage
import ImageIO

/// 色調転写: 参照画像の色調(チャンネルごとの平均と標準偏差)に、映像の色調を寄せる。
/// Reinhard らの統計的な色調転写の簡易版で、sRGB の符号化値のままチャンネル独立に
/// 「平均を参照の平均へ、ばらつきを参照のばらつきへ」写す(参照が単色なら全体がその色に寄る)。
/// 計算(統計・写像・立方体)は純粋な関数でテストでき、描画は CIColorCube でかける(LUT やカラーホイールと同じ経路)。
/// クリップ自身の統計は、かける直前の絵を小さくして測る(コマごとに測るので動画でも追随する)。
public enum ColorTransfer {
    /// 色調の統計(チャンネルごとの平均と標準偏差。0〜1 の sRGB 符号化値)。
    public struct Stats: Equatable, Sendable {
        public var mean: [Double]
        public var std: [Double]
        public init(mean: [Double], std: [Double]) {
            self.mean = mean
            self.std = std
        }
    }

    /// CIColorCube の 1 辺(32³ = 32768 点。品質と速さの釣り合い)。
    public static let cubeDimension = 32
    /// 元のばらつきがこれ未満のチャンネルは、割り算が暴れないようこの値で割る(単色のコマでも平均だけは合う)。
    static let minStd = 0.01
    /// 統計を測る縮小画像の最大の辺(画素)。
    static let measureMaxPixel = 128
    /// 参照画像を読み込むときの最大の辺(画素)。
    static let referenceMaxPixel = 256

    // MARK: 統計

    /// premultiplied RGBA8(0〜255)から統計を測る。ほぼ透明な画素(アルファ 128 未満)は数えない
    /// (透明な所は premultiplied で黒になり、色調を引っ張ってしまうため)。数える画素が無ければ nil。
    public static func stats(rgba: [UInt8], count: Int) -> Stats? {
        guard count > 0, count <= rgba.count / 4 else { return nil }
        var sum = [0.0, 0.0, 0.0], sq = [0.0, 0.0, 0.0]
        var n = 0.0
        for i in 0..<count {
            let a = Double(rgba[i * 4 + 3])
            guard a >= 128 else { continue }
            n += 1
            for c in 0..<3 {
                // premultiplied を元に戻す(premultiplied 値 ÷ アルファ = 0〜1 の色)
                let v = Double(rgba[i * 4 + c]) / a
                sum[c] += v
                sq[c] += v * v
            }
        }
        guard n > 0 else { return nil }
        var mean = [0.0, 0.0, 0.0], std = [0.0, 0.0, 0.0]
        for c in 0..<3 {
            mean[c] = sum[c] / n
            std[c] = (max(0, sq[c] / n - mean[c] * mean[c])).squareRoot()
        }
        return Stats(mean: mean, std: std)
    }

    /// CGImage の統計(そのままの大きさで測るので、呼び出し側で小さくしておくこと)。
    public static func stats(of image: CGImage) -> Stats? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        return stats(rgba: buf, count: w * h)
    }

    /// 画像ファイルの統計(縮小してから測る)。読めない・画像でないときは nil。
    public static func stats(ofFile path: String) -> Stats? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let src = CGImageSourceCreateWithURL(url, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: referenceMaxPixel,
            kCGImageSourceShouldCache: false,
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return stats(of: img)
    }

    // MARK: 写像

    /// 1 色(0〜1 の RGB)を転写する。`strength` は元の色との混ぜ具合(0 = 何もしない、1 = 統計を一致させる)。
    /// 元の平均色は参照の平均色へ写り、ばらつきは比(std の商)で拡縮する。結果は 0〜1 に収める。
    public static func transferred(_ rgb: [Double], src: Stats, ref: Stats, strength: Double) -> [Double] {
        let k = min(max(strength, 0), 1)
        guard rgb.count == 3, src.mean.count == 3, ref.mean.count == 3, src.std.count == 3, ref.std.count == 3 else { return rgb }
        var out = [0.0, 0.0, 0.0]
        for c in 0..<3 {
            let s = max(src.std[c], minStd)
            let t = (rgb[c] - src.mean[c]) * (ref.std[c] / s) + ref.mean[c]
            out[c] = min(max(rgb[c] * (1 - k) + t * k, 0), 1)
        }
        return out
    }

    /// CIColorCube 用のデータ(RGBA float・premultiplied、赤が一番速く動く並び)。アルファはそのまま(1 を掛ける)。
    public static func cubeData(src: Stats, ref: Stats, strength: Double) -> Data {
        cubeData(src: src, ref: ref, strength: strength, dimension: cubeDimension)
    }

    static func cubeData(src: Stats, ref: Stats, strength: Double, dimension: Int) -> Data {
        let n = dimension
        var floats = [Float]()
        floats.reserveCapacity(n * n * n * 4)
        let step = 1 / Double(n - 1)
        for b in 0..<n { for g in 0..<n { for r in 0..<n {
            let m = transferred([Double(r) * step, Double(g) * step, Double(b) * step], src: src, ref: ref, strength: strength)
            floats.append(Float(m[0])); floats.append(Float(m[1])); floats.append(Float(m[2])); floats.append(1)
        } } }
        return floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    // MARK: 描画

    private static let cubeLock = NSLock()
    private static var cubeCache: [(key: String, data: Data)] = []

    /// 統計の組み合わせごとに立方体を覚える(静止画や同じコマの再描画で作り直さない)。
    /// 鍵は丸めない(丸めると、違う統計が同じ鍵になって、先に作った立方体が使い回される)。
    static func cachedCubeData(src: Stats, ref: Stats, strength: Double) -> Data {
        func q(_ v: [Double]) -> String { v.map { "\($0)" }.joined(separator: ",") }
        let key = "\(q(src.mean))|\(q(src.std))|\(q(ref.mean))|\(q(ref.std))|\(strength)"
        cubeLock.lock()
        if let hit = cubeCache.first(where: { $0.key == key }) { cubeLock.unlock(); return hit.data }
        cubeLock.unlock()
        let data = cubeData(src: src, ref: ref, strength: strength)
        cubeLock.lock()
        if cubeCache.count > 8 { cubeCache.removeAll() }
        cubeCache.append((key, data))
        cubeLock.unlock()
        return data
    }

    /// かける直前の絵の統計(小さく描いて測る)。`extent` は元の絵の範囲(無限の範囲を持つ絵でもここで切る)。
    static func sourceStats(of img: CIImage, extent: CGRect) -> Stats? {
        let bounded = img.cropped(to: extent)
        let ext = bounded.extent
        guard ext.width > 0, ext.height > 0, ext.width.isFinite, ext.height.isFinite else { return nil }
        let scale = min(1, Double(measureMaxPixel) / max(ext.width, ext.height))
        let small = scale < 1 ? bounded.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : bounded
        guard let cg = ciContext.createCGImage(small, from: small.extent, format: .BGRA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { return nil }
        return stats(of: cg)
    }

    /// 参照の統計へ寄せる。元の絵の統計が測れない(真っ透明など)ときは何もしない。
    /// `extent` は入力の範囲(EffectPipeline の作業範囲)。出力の範囲は入力と同じ。
    public static func apply(_ img: CIImage, ref: Stats, strength: Double, extent: CGRect) -> CIImage {
        let k = min(max(strength, 0), 1)
        guard k > 0, let src = sourceStats(of: img, extent: extent) else { return img }
        let data = cachedCubeData(src: src, ref: ref, strength: k)
        return img.unpremultiplyingAlpha()
            .applyingFilter("CIColorCube", parameters: ["inputCubeDimension": cubeDimension, "inputCubeData": data])
            .premultiplyingAlpha()
    }
}

/// 参照画像の統計の置き場(LUTCache と同じ流儀: パス + 更新日時 + サイズで見分ける。壊れたファイルも覚える)。
public final class ReferenceColorCache: @unchecked Sendable {
    public static let shared = ReferenceColorCache()
    struct Key: Hashable { var path: String; var mtime: Double; var size: Int }
    private let lock = NSLock()
    private var cache: [Key: ColorTransfer.Stats?] = [:]

    private func key(_ path: String) -> Key? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        let m = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return Key(path: path, mtime: m, size: (a[.size] as? NSNumber)?.intValue ?? 0)
    }

    /// 読めたら統計。無い・画像として読めないときは nil。
    public func stats(atPath path: String) -> ColorTransfer.Stats? {
        guard let k = key(path) else { return nil }
        lock.lock()
        if let hit = cache[k] { lock.unlock(); return hit }
        lock.unlock()
        let s = ColorTransfer.stats(ofFile: path)
        lock.lock()
        if cache.count > 16 { cache.removeAll() }
        cache[k] = .some(s)
        lock.unlock()
        return s
    }

    /// そのパスのファイルが参照画像として読めるか(インスペクタの表示用)。
    public func status(atPath path: String) -> Status {
        guard FileManager.default.fileExists(atPath: path) else { return .missing }
        return stats(atPath: path) == nil ? .invalid : .ok
    }
    public enum Status: Equatable, Sendable { case ok, missing, invalid }
}
