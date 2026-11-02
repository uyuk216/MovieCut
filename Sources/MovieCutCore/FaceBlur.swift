import Foundation
import CoreGraphics
import CoreImage
import Vision

// MARK: - 顔の検出

/// 顔の検出器。返す矩形は 0〜1 の正規化座標・左上原点(画像の幅・高さで割った値)。テストでは偽物を差し込む。
public protocol FaceDetecting: Sendable {
    func faces(in image: CGImage) -> [CGRect]
}

/// Vision の VNDetectFaceRectanglesRequest。検出は長辺 480 px に縮小してから行う(速さのため。座標は正規化なので変わらない)。
/// 顔が無い・検出に失敗したときは空の配列(何もぼかさない)。
public struct VisionFaceDetector: FaceDetecting {
    public static let maxSide = 480
    public init() {}

    public func faces(in image: CGImage) -> [CGRect] {
        guard let small = Self.downscaled(image, maxSide: Self.maxSide) else { return [] }
        let request = VNDetectFaceRectanglesRequest()
        do { try VNImageRequestHandler(cgImage: small, options: [:]).perform([request]) } catch { return [] }
        return (request.results ?? []).map { o in
            let b = o.boundingBox   // 正規化・左下原点
            return CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
        }
    }

    static func downscaled(_ image: CGImage, maxSide: Int) -> CGImage? {
        let longest = max(image.width, image.height)
        guard longest > 0 else { return nil }
        let k = min(1, Double(maxSide) / Double(longest))
        let w = max(1, Int((Double(image.width) * k).rounded())), h = max(1, Int((Double(image.height) * k).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}

/// 検出結果のキャッシュ(キーは「クリップ・時刻・配置・素材」の文字列)。同じ時刻の再描画(プレビューの戻し・書き出しの再試行)で検出を繰り返さない。
/// 件数が上限を超えたら全部捨てる(単純・メモリを抑える)。
public final class FaceDetectionCache: @unchecked Sendable {
    /// テストでは検出器を差し替える(本番の既定は変えない)。
    public static var shared = FaceDetectionCache()
    public static let capacity = 600

    private let lock = NSLock()
    private var store: [String: [CGRect]] = [:]
    private let detector: FaceDetecting

    public init(detector: FaceDetecting = VisionFaceDetector()) { self.detector = detector }

    public func rects(key: String, image: CGImage) -> [CGRect] { rects(key: key) { image } }

    /// 鍵が無いときだけ `make` で画像を作って検出する(作るのも検出も鍵の外。作れなければ空)。
    public func rects(key: String, make: () -> CGImage?) -> [CGRect] {
        lock.lock()
        if let v = store[key] { lock.unlock(); return v }
        lock.unlock()
        guard let image = make() else { return [] }
        let v = detector.faces(in: image)   // 検出は鍵の外で(他のスレッドを待たせない)
        lock.lock()
        if store.count >= Self.capacity { store.removeAll(keepingCapacity: true) }
        store[key] = v
        lock.unlock()
        return v
    }

    public var count: Int { lock.lock(); defer { lock.unlock() }; return store.count }
    public func clear() { lock.lock(); store.removeAll(); lock.unlock() }
}

// MARK: - 顔ぼかしの計算

/// 検出された顔の枠に、モザイクかぼかしをかける。枠の外の画素は変えない(マスクで切る)。
/// 1920×1080 基準の大きさ(`scale` で解像度に合わせる)。
public enum FaceBlur {
    /// 検出枠の各辺に足す余白(枠の幅・高さに対する割合)。
    public static let padding = 0.25

    public enum Mode: Sendable, Equatable {
        case mosaic, blur
        /// 引数の値(0 = モザイク、0.5 以上 = ぼかし)。
        public init(_ v: Double) { self = v >= 0.5 ? .blur : .mosaic }
    }

    /// 強さ 0〜1 → モザイクのブロックの大きさ(1080p での px)。
    public static func blockSize(strength s: Double, scale: Double) -> Double { (4 + 56 * min(max(s, 0), 1)) * scale }
    /// 強さ 0〜1 → ぼかしの σ(1080p での px)。
    public static func sigma(strength s: Double, scale: Double) -> Double { (2 + 38 * min(max(s, 0), 1)) * scale }

    /// 正規化・左上原点の検出枠 → 画像の座標(左下原点)のピクセル枠。余白を足し、画像の範囲に収める。空になるものは落とす。
    public static func pixelRects(_ faces: [CGRect], in extent: CGRect) -> [CGRect] {
        faces.compactMap { f in
            guard f.width > 0, f.height > 0, f.minX.isFinite, f.minY.isFinite else { return nil }
            let g = f.insetBy(dx: -f.width * padding, dy: -f.height * padding)
            let r = CGRect(x: extent.minX + g.minX * extent.width,
                           y: extent.minY + (1 - g.maxY) * extent.height,
                           width: g.width * extent.width, height: g.height * extent.height)
                .intersection(extent)
            return r.isNull || r.isEmpty ? nil : r
        }
    }

    /// 顔の枠だけを、モザイクまたはぼかしにした画像。`strength` が 0 か、枠が無ければ入力のまま。
    /// `blockPx` は 1080p 基準のモザイクの大きさ(無ければ強さから決める)。
    public static func apply(_ img: CIImage, faces: [CGRect], mode: Mode, strength: Double, scale: Double, blockPx: Double? = nil) -> CIImage {
        let extent = img.extent
        let s = min(max(strength, 0), 1)
        let rects = pixelRects(faces, in: extent)
        guard !rects.isEmpty, s > 0, !extent.isInfinite, !extent.isEmpty else { return img }
        let effect: CIImage
        switch mode {
        case .mosaic:
            effect = img.applyingFilter("CIPixellate", parameters: [
                "inputCenter": CIVector(x: extent.minX, y: extent.minY), "inputScale": max(2, blockPx.map { $0 * scale } ?? blockSize(strength: s, scale: scale)),
            ]).cropped(to: extent)
        case .blur:
            effect = img.clampedToExtent().applyingGaussianBlur(sigma: sigma(strength: s, scale: scale)).cropped(to: extent)
        }
        var mask = CIImage(color: CIColor.white).cropped(to: rects[0])
        for r in rects.dropFirst() { mask = CIImage(color: CIColor.white).cropped(to: r).composited(over: mask) }
        return effect.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: img, kCIInputMaskImageKey: mask,
        ]).cropped(to: extent)
    }
}
