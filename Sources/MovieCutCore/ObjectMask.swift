import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

// MARK: - オブジェクトマスク(Premiere Pro の AI オブジェクトマスクのローカル等価)
//
// 人物・物体を 1 クリック(または矩形指定)で選び、前景インスタンスマスク(Vision)で輪郭の
// 初期マスクを作り、`ObjectTracking`(Vision の矩形追跡)でショット全体へ時間方向に伝播させ、
// `ClipMask` と同じ描画経路(エフェクトの後にマスクを画素へかける)で適用するマスク。
// 形マスク(`ClipMask`)とは別項目 `Clip.objectMask` として保存し、両方あるときは両方かかる。
//
// 保存の形:
// - `seedMask`: 種コマの輪郭マスク(対象の外接矩形へ切り抜き、長辺 256px へ縮小した
//   グレースケール PNG の Base64)。ファイルが大きくなりすぎないための要。
// - `samples`: 0.1 秒ごとの外接矩形(追跡結果)。輪郭は原則 `seedMask` を矩形に合わせて
//   拡縮して使う。1 秒ごとの再検出で形が変わったサンプルだけ `mask` を持つ(まばら)。
// - 回転は追従しない(矩形は軸平行のまま)。Premiere の 27.0 世代の追跡改善・復元とは違い、
//   見失った区間は `ObjectTrack.maxGap` と同じ作法で「近い検出を最大 1 秒まで使う」。

/// オブジェクトマスクの 1 サンプル。`t` はクリップの頭からの秒。見失った時刻は `rect == nil`。
public struct ObjectMaskSample: Codable, Equatable, Sendable {
    public var t: Double
    /// 対象の外接矩形(キャンバスに対する割合・左上原点)。見失いは nil。
    public var rect: TrackRect?
    /// この時刻の輪郭マスク(外接矩形へ切り抜いたグレースケール PNG の Base64)。
    /// 無いときは種マスク(`ObjectMask.seedMask`)を矩形に合わせて使う。
    public var mask: String?

    public init(t: Double, rect: TrackRect?, mask: String? = nil) {
        self.t = t; self.rect = rect; self.mask = mask
    }

    enum CodingKeys: String, CodingKey { case t, rect, mask }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        t = (try? c.decodeIfPresent(Double.self, forKey: .t)) ?? 0
        rect = try? c.decodeIfPresent(TrackRect.self, forKey: .rect)
        mask = try? c.decodeIfPresent(String.self, forKey: .mask)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(t, forKey: .t)
        try c.encodeIfPresent(rect, forKey: .rect)
        try c.encodeIfPresent(mask, forKey: .mask)
    }
}

/// オブジェクトマスク(クリップに保存される)。`ClipMask` と同じ約束:
/// 既定値の項目は書かず、知らないキーは `extra` に残してそのまま書き戻す。
public struct ObjectMask: Codable, Equatable, Sendable {
    /// 追跡元のクリップ(`Clip.id`。通常はマスクを持つクリップ自身)。
    public var sourceClipId: String
    /// 種マスクを取った時刻(クリップの頭からの秒)。
    public var seedTime: Double
    /// 種マスクの外接矩形(基準)。
    public var seedRect: TrackRect
    /// 種マスクの輪郭(グレースケール PNG の Base64、外接矩形へ切り抜き・縮小済み)。
    public var seedMask: String?
    /// 羽根(0 = くっきり、1 = 短い辺の 1/4 ぶんのなだらかさ)。`ClipMask` と同じ定義。
    public var feather: Double
    /// true で外を残し、中を透明にする。
    public var invert: Bool
    /// サンプル列(時刻順)。
    public var samples: [ObjectMaskSample]

    public init(sourceClipId: String, seedTime: Double = 0, seedRect: TrackRect,
                seedMask: String? = nil, feather: Double = 0, invert: Bool = false,
                samples: [ObjectMaskSample] = []) {
        self.sourceClipId = sourceClipId
        self.seedTime = seedTime.isFinite ? max(0, seedTime) : 0
        self.seedRect = seedRect
        self.seedMask = seedMask
        self.feather = ClipMask.clampUnit(feather)
        self.invert = invert
        self.samples = samples
    }

    /// 検出の無い区間をまたいで補間してよい最大の間隔(秒)。`ObjectTrack.maxGap` と同じ。
    public static let maxGap = ObjectTrack.maxGap

    public var hasValidSamples: Bool { samples.contains { $0.rect?.isValid == true } }

    /// 時刻・値の整え(読み込み時)。
    public var normalized: ObjectMask {
        var o = self
        o.seedTime = seedTime.isFinite ? max(0, seedTime) : 0
        o.seedRect = seedRect.normalized
        o.feather = ClipMask.clampUnit(feather)
        if let s = o.seedMask, s.isEmpty { o.seedMask = nil }
        o.samples = samples.filter { $0.t.isFinite && $0.t >= 0 }
            .map { ObjectMaskSample(t: $0.t, rect: $0.rect?.normalized, mask: ($0.mask?.isEmpty == true) ? nil : $0.mask) }
            .sorted { $0.t < $1.t }
        return o
    }

    /// 時刻 t の外接矩形。前後を線形補間する。作法は `ObjectTrack.rect(at:)` と同じ。
    public func rect(at t: Double) -> TrackRect? {
        guard t.isFinite else { return nil }
        let valid = samples.filter { $0.rect?.isValid == true }
        guard !valid.isEmpty else { return nil }
        let before = valid.last { $0.t <= t }
        let after = valid.first { $0.t >= t }
        switch (before, after) {
        case let (b?, a?) where b.t == a.t:
            return b.rect
        case let (b?, a?):
            if a.t - b.t <= 2 * Self.maxGap, let p = b.rect, let q = a.rect {
                let k = (t - b.t) / (a.t - b.t)
                return TrackRect(x: p.x + (q.x - p.x) * k, y: p.y + (q.y - p.y) * k,
                                 w: p.w + (q.w - p.w) * k, h: p.h + (q.h - p.h) * k)
            }
            if t - b.t <= Self.maxGap { return b.rect }
            if a.t - t <= Self.maxGap { return a.rect }
            return nil
        case let (b?, nil):
            return t - b.t <= Self.maxGap ? b.rect : nil
        case let (nil, a?):
            return a.t - t <= Self.maxGap ? a.rect : nil
        default:
            return nil
        }
    }

    /// 時刻 t で使う輪郭マスク(Base64)。時刻に近いサンプルの `mask` を優先し、
    /// 無ければ種マスク。どちらも無ければ nil(描画は楕円で近似する)。
    public func maskBase64(at t: Double) -> String? {
        let withMask = samples.filter { $0.mask != nil && $0.rect?.isValid == true }
        if let near = withMask.min(by: { abs($0.t - t) < abs($1.t - t) }), abs(near.t - t) <= Self.maxGap {
            return near.mask
        }
        return seedMask
    }

    // MARK: ファイル形式(ClipMask と同じ作法)

    enum CodingKeys: String, CodingKey { case sourceClipId, seedTime, seedRect, seedMask, feather, invert, samples }
    /// 知らないキー(新しい版が書いた項目)。そのまま書き戻す。
    public var extra: [String: JSONValue] = [:]
    static let knownKeys: Set<String> = ["sourceClipId", "seedTime", "seedRect", "seedMask", "feather", "invert", "samples"]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sourceClipId = (try? c.decodeIfPresent(String.self, forKey: .sourceClipId)) ?? ""
        seedTime = (try? c.decodeIfPresent(Double.self, forKey: .seedTime)) ?? 0
        seedRect = (try? c.decodeIfPresent(TrackRect.self, forKey: .seedRect)) ?? TrackRect(x: 0.35, y: 0.35, w: 0.3, h: 0.3)
        seedMask = try? c.decodeIfPresent(String.self, forKey: .seedMask)
        feather = (try? c.decodeIfPresent(Double.self, forKey: .feather)) ?? 0
        invert = (try? c.decodeIfPresent(Bool.self, forKey: .invert)) ?? false
        samples = (try? c.decodeIfPresent([ObjectMaskSample].self, forKey: .samples)) ?? []
        // init の整え(範囲外の値の丸め)を効かせる
        let fixed = ObjectMask(sourceClipId: sourceClipId, seedTime: seedTime, seedRect: seedRect,
                               seedMask: seedMask, feather: feather, invert: invert, samples: samples)
        seedTime = fixed.seedTime; feather = fixed.feather
        extra = Lenient(c: try decoder.container(keyedBy: AnyKey.self), known: Self.knownKeys).extra()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        for (k, v) in extra { try c.encode(v, forKey: AnyKey(k)) }
        try c.encode(sourceClipId, forKey: AnyKey("sourceClipId"))
        if seedTime > 0 { try c.encode(seedTime, forKey: AnyKey("seedTime")) }
        try c.encode(seedRect, forKey: AnyKey("seedRect"))
        try c.encodeIfPresent(seedMask, forKey: AnyKey("seedMask"))
        if feather > 0 { try c.encode(feather, forKey: AnyKey("feather")) }
        if invert { try c.encode(true, forKey: AnyKey("invert")) }
        try c.encode(samples, forKey: AnyKey("samples"))
    }
}

// MARK: - 伝播と選択(純粋な計算)

public enum ObjectMaskPropagation {
    /// 追跡結果(矩形列)からマスクのサンプル列を作る。輪郭は種マスクを共有するので、
    /// ここでは矩形だけを持たせる(時刻ごとの輪郭は再検出で後から付け足す)。
    public static func samples(from track: ObjectTrack) -> [ObjectMaskSample] {
        track.samples.map { ObjectMaskSample(t: $0.t, rect: $0.rect) }
    }

    /// 追跡結果と種マスクからオブジェクトマスクを作る。有効なサンプルが無ければ nil。
    public static func build(sourceClipId: String, seedTime: Double, seedRect: TrackRect,
                             seedMaskBase64: String?, track: ObjectTrack,
                             feather: Double = 0, invert: Bool = false) -> ObjectMask? {
        guard track.hasValidSamples else { return nil }
        return ObjectMask(sourceClipId: sourceClipId, seedTime: seedTime, seedRect: seedRect,
                          seedMask: seedMaskBase64, feather: feather, invert: invert,
                          samples: samples(from: track)).normalized
    }

    /// 2 矩形の重なり面積(正規化座標)。重ならなければ 0。
    public static func overlapArea(_ a: TrackRect, _ b: TrackRect) -> Double {
        let w = min(a.x + a.w, b.x + b.w) - max(a.x, b.x)
        let h = min(a.y + a.h, b.y + b.h) - max(a.y, b.y)
        return (w > 0 && h > 0) ? w * h : 0
    }

    /// クリック点を含むインスタンスを選ぶ。複数含めば一番小さいもの(狙った対象に近い)、
    /// どれも含まなければ中心が一番近いもの。候補が無ければ nil。
    public static func pickInstance(at point: CGPoint, instances: [TrackRect]) -> Int? {
        let valid = instances.enumerated().filter { $0.element.isValid }
        guard !valid.isEmpty else { return nil }
        let containing = valid.filter { r in
            point.x >= CGFloat(r.element.x) && point.x <= CGFloat(r.element.x + r.element.w)
                && point.y >= CGFloat(r.element.y) && point.y <= CGFloat(r.element.y + r.element.h)
        }
        if let best = containing.min(by: { $0.element.area < $1.element.area }) { return best.offset }
        return valid.min(by: {
            let dx0 = $0.element.centerX - Double(point.x), dy0 = $0.element.centerY - Double(point.y)
            let dx1 = $1.element.centerX - Double(point.x), dy1 = $1.element.centerY - Double(point.y)
            return dx0 * dx0 + dy0 * dy0 < dx1 * dx1 + dy1 * dy1
        })?.offset
    }

    /// 指定矩形に一番合うインスタンスを選ぶ。合致度は IoU(重なり ÷ 合体面積)で、
    /// 大きな背景物が「重なり面積が大きい」だけで勝たないようにする。同点なら重なり面積が大きい方。
    /// 重なりが無ければ nil。
    public static func pickInstance(overlapping rect: TrackRect, instances: [TrackRect]) -> Int? {
        var best: (index: Int, iou: Double, area: Double)? = nil
        for (i, r) in instances.enumerated() where r.isValid {
            let a = overlapArea(rect, r)
            guard a > 0 else { continue }
            let union = rect.area + r.area - a
            let iou = union > 0 ? a / union : 0
            if iou > (best?.iou ?? -1) || (iou == best?.iou && a > (best?.area ?? 0)) { best = (i, iou, a) }
        }
        return best?.index
    }

    /// 再検出で得た輪郭を、時刻が一番近いサンプルへ付け足す(まばらな輪郭の更新)。
    /// 付け足せたら true。対象サンプルが無ければ何もしない。
    @discardableResult
    public static func attachMask(_ maskBase64: String, at t: Double, to mask: inout ObjectMask, tolerance: Double = 0.51) -> Bool {
        guard let i = mask.samples.indices.min(by: { abs(mask.samples[$0].t - t) < abs(mask.samples[$1].t - t) }),
              abs(mask.samples[i].t - t) <= tolerance, mask.samples[i].rect?.isValid == true else { return false }
        mask.samples[i].mask = maskBase64
        return true
    }
}

// MARK: - マスク画像の読み書き・測定

public enum ObjectMaskImage {
    /// 保存時の輪郭マスクの長辺(px)。ファイルの大きさと復元の粗さの釣り合い。
    public static let storedMaxSide = 256

    /// グレースケール PNG の Base64 文字列にする(長辺 `maxSide` へ縮小してから)。
    public static func pngBase64(of image: CGImage, maxSide: Int = storedMaxSide) -> String? {
        let img = downscaled(image, maxSide: maxSide)
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (data as Data).base64EncodedString()
    }

    /// Base64 の PNG を読む。壊れていれば nil。
    public static func image(fromBase64 s: String?) -> CGImage? {
        guard let s, let data = Data(base64Encoded: s),
              let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// 長辺が `maxSide` を超えるときだけ縮小する(縦横比は保つ)。以下ならそのまま。
    public static func downscaled(_ image: CGImage, maxSide: Int) -> CGImage {
        let w = image.width, h = image.height
        guard w > 0, h > 0, max(w, h) > maxSide, maxSide > 0 else { return image }
        let scale = Double(maxSide) / Double(max(w, h))
        let nw = max(1, Int((Double(w) * scale).rounded())), nh = max(1, Int((Double(h) * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: nw, height: nh))
        return ctx.makeImage() ?? image
    }

    /// マスク画像(白 = 前景)の白い画素の外接矩形(画像に対する割合・左上原点)。
    /// 閾値以上の画素が無ければ nil。グレースケールへ描き直して走査する。
    public static func boundingRect(ofMask image: CGImage, threshold: UInt8 = 127) -> TrackRect? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        var px = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        // バッファの 1 行目が画像の上端になるよう上下を反転して描く
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            let row = y * w
            for x in 0..<w where px[row + x] > threshold {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= 0 else { return nil }
        return TrackRect(x: Double(minX) / Double(w), y: Double(minY) / Double(h),
                         w: Double(maxX - minX + 1) / Double(w), h: Double(maxY - minY + 1) / Double(h))
    }

    /// 正規化矩形(左上原点)で画像を切り抜く。範囲が画像の外なら nil。
    public static func cropped(_ image: CGImage, toNormalized rect: TrackRect) -> CGImage? {
        let w = Double(image.width), h = Double(image.height)
        guard w > 0, h > 0, rect.isValid else { return nil }
        let r = CGRect(x: rect.x * w, y: rect.y * h, width: rect.w * w, height: rect.h * h)
            .intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard !r.isNull, r.width >= 1, r.height >= 1 else { return nil }
        return image.cropping(to: r)
    }
}

// MARK: - 描画(ClipMask の ShapeMask と同じ経路)

public enum ObjectMaskRenderer {
    // 復号した輪郭画像の小さなキャッシュ(書き出し・プレビューの毎コマ復号を避ける)。
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: CGImage] = [:]

    static func decoded(_ base64: String?) -> CGImage? {
        guard let base64 else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[base64] { return hit }
        guard let img = ObjectMaskImage.image(fromBase64: base64) else { return nil }
        if cache.count > 32 { cache.removeAll() }
        cache[base64] = img
        return img
    }

    /// キャンバス(左下原点の CI 座標)いっぱいの、白(残す)と黒(消す)のマスク。
    /// 時刻 t で対象が見つからなければ nil(呼び出し側は何もしない)。
    public static func canvasImage(_ om: ObjectMask, at t: Double, width W: Double, height H: Double) -> CIImage? {
        guard let rect = om.rect(at: t) else { return nil }
        let canvas = CGRect(x: 0, y: 0, width: W, height: H)
        let rx = rect.x * W, ry = H - (rect.y + rect.h) * H   // 左下原点の矩形の左下
        let rw = max(1, rect.w * W), rh = max(1, rect.h * H)
        var shape: CIImage
        if let cg = decoded(om.maskBase64(at: t)) {
            // 輪郭画像を外接矩形へぴったり拡縮して置く(座標は左下原点へ変換済み)
            let src = CIImage(cgImage: cg)
            let sx = rw / max(1, src.extent.width), sy = rh / max(1, src.extent.height)
            shape = src.transformed(by: CGAffineTransform(a: sx, b: 0, c: 0, d: sy, tx: rx, ty: ry))
        } else {
            // 輪郭が無いサンプルは、矩形に内接する楕円で近似する(ShapeMask の楕円と同じ作り)
            let grad = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: 0, y: 0), "inputRadius0": 1.0, "inputRadius1": 1.0 + 1e-3,
                "inputColor0": CIColor(red: 1, green: 1, blue: 1), "inputColor1": CIColor(red: 0, green: 0, blue: 0),
            ])?.outputImage ?? CIImage(color: .black)
            shape = grad.transformed(by: CGAffineTransform(a: rw / 2, b: 0, c: 0, d: rh / 2, tx: rx + rw / 2, ty: ry + rh / 2))
        }
        // 羽根: 輪郭をぼかす(境目は 50%)
        let sigma = om.feather * min(rw, rh) * 0.25
        if sigma > 0.01 { shape = shape.applyingGaussianBlur(sigma: sigma) }
        var out = shape.composited(over: CIImage(color: .black).cropped(to: canvas)).cropped(to: canvas)
        if om.invert { out = out.applyingFilter("CIColorInvert") }
        return out
    }

    /// `ShapeMask.apply` と同じ作法で、オブジェクトマスクを画素へかける。
    /// 時刻 t で対象が無ければ画像をそのまま返す。
    public static func apply(_ img: CIImage, objectMask om: ObjectMask, at t: Double,
                             canvasWidth W: Double, canvasHeight H: Double,
                             originX: Double, originY: Double) -> CIImage {
        guard let canvasMask = canvasImage(om, at: t, width: W, height: H) else { return img }
        let ext = img.extent
        let local = canvasMask.transformed(by: CGAffineTransform(translationX: -originX, y: -(H - originY - ext.height)))
        let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: ext)
        return img.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: clear,
            kCIInputMaskImageKey: local.cropped(to: ext),
        ]).cropped(to: ext)
    }
}
