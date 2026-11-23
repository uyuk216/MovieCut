import Foundation
import CoreGraphics
import CoreImage

/// ペンマスクの制御点(割合・左上原点)。`x`/`y` がアンカー(頂点)、`inX`/`inY` が入ってくる側の
/// ハンドル、`outX`/`outY` が出ていく側のハンドル(どちらもアンカーからの絶対座標)。
/// ハンドルがアンカーと一致するときは直線になる。ファイルでは、アンカーと違うハンドルだけ書く。
public struct MaskPoint: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var inX: Double
    public var inY: Double
    public var outX: Double
    public var outY: Double

    public init(x: Double, y: Double, inX: Double? = nil, inY: Double? = nil, outX: Double? = nil, outY: Double? = nil) {
        self.x = ClipMask.clampUnit(x); self.y = ClipMask.clampUnit(y)
        self.inX = ClipMask.clampUnit(inX ?? x); self.inY = ClipMask.clampUnit(inY ?? y)
        self.outX = ClipMask.clampUnit(outX ?? x); self.outY = ClipMask.clampUnit(outY ?? y)
    }

    /// 座標を 0〜1 に収めた複製(直接書き換えた値の正規化用)。
    public var normalized: MaskPoint {
        MaskPoint(x: x, y: y, inX: inX, inY: inY, outX: outX, outY: outY)
    }

    /// ハンドルが両方ともアンカーと一致する(角・直線の点)か。
    public var isCorner: Bool {
        abs(inX - x) < 1e-12 && abs(inY - y) < 1e-12 && abs(outX - x) < 1e-12 && abs(outY - y) < 1e-12
    }

    static let knownKeys: Set<String> = ["x", "y", "inX", "inY", "outX", "outY"]
}

extension MaskPoint: Codable {
    public init(from decoder: Decoder) throws {
        let l = Lenient(c: try decoder.container(keyedBy: AnyKey.self), known: Self.knownKeys)
        let x = l.double("x") ?? 0.5, y = l.double("y") ?? 0.5
        self.init(x: x, y: y, inX: l.double("inX"), inY: l.double("inY"), outX: l.double("outX"), outY: l.double("outY"))
    }

    public func encode(to encoder: Encoder) throws {
        let p = normalized
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encode(p.x, forKey: AnyKey("x"))
        try c.encode(p.y, forKey: AnyKey("y"))
        if p.inX != p.x { try c.encode(p.inX, forKey: AnyKey("inX")) }
        if p.inY != p.y { try c.encode(p.inY, forKey: AnyKey("inY")) }
        if p.outX != p.x { try c.encode(p.outX, forKey: AnyKey("outX")) }
        if p.outY != p.y { try c.encode(p.outY, forKey: AnyKey("outY")) }
    }
}

/// クリップの形のマスク。キャンバスの中の矩形・楕円・ペン(ベジェの閉じたパス)(0〜1・左上原点)で、中を残し外を透明にする(反転・羽根付き)。
/// エフェクトの後にかける(`Renderer`)。省いたとき(nil)は何もしない。ファイルでは、`shape` 以外は既定値のときは書かない。
/// ペンのときは `x`/`y`/`w`/`h` は使わず、`points`(制御点の列)が形を決める。点が 3 未満のペンは面積を持たない(全面が外)。
public struct ClipMask: Codable, Equatable, Sendable {
    public static let shapes = ["rect", "ellipse", "pen"]
    /// ペンの制御点の上限(暴走したファイル・操作から守る)。
    public static let maxPoints = 64
    /// 形: "rect"(矩形)・"ellipse"(楕円)・"pen"(ペン/ベジェ)。
    public var shape: String
    /// 位置・大きさ(キャンバスの幅・高さに対する割合・左上原点)。ペンでは使わない(値は保持される)。
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double
    /// 羽根(0 = くっきり、1 = 短い辺の 1/4 ぶんのなだらかさ)。
    public var feather: Double
    /// true で外を残し、中を透明にする。
    public var invert: Bool
    /// ペンの制御点(閉じたパス。最後の点から最初の点へも曲線でつながる)。ペン以外の形では空で、ファイルにも書かない。
    public var points: [MaskPoint]

    public init(shape: String = "rect", x: Double = 0.25, y: Double = 0.25, w: Double = 0.5, h: Double = 0.5, feather: Double = 0, invert: Bool = false, points: [MaskPoint] = []) {
        self.shape = Self.shapes.contains(shape) ? shape : "rect"
        self.x = Self.clampUnit(x); self.y = Self.clampUnit(y)
        self.w = min(max(w, 0.01), 1); self.h = min(max(h, 0.01), 1)
        self.feather = Self.clampUnit(feather); self.invert = invert
        self.points = Self.normalizedPoints(points)
    }

    static func clampUnit(_ v: Double) -> Double { v.isFinite ? min(max(v, 0), 1) : 0 }

    static func normalizedPoints(_ pts: [MaskPoint]) -> [MaskPoint] {
        Array(pts.prefix(maxPoints)).map { $0.normalized }
    }

    /// ペンに切り替えた直後(点が無いとき)に置く既定の菱形。まっすぐな 4 点で、中心を含む。
    public static let defaultPenPoints: [MaskPoint] = [
        MaskPoint(x: 0.5, y: 0.25), MaskPoint(x: 0.75, y: 0.5),
        MaskPoint(x: 0.5, y: 0.75), MaskPoint(x: 0.25, y: 0.5),
    ]

    /// ペンの点が無ければ既定の菱形を用意する(形をペンへ切り替える操作用)。
    public mutating func ensurePenPoints() {
        if points.isEmpty { points = Self.defaultPenPoints }
    }

    /// 面積のあるペンか(点が 3 以上)。
    public var hasPenArea: Bool { shape == "pen" && points.count >= 3 }

    // MARK: ペンの幾何(純粋な計算。ラスタライズと内外判定とプレビューの線が共有する)

    /// 3 次ベジェの 1 点。`p0`→`p3`、制御点 `p1`/`p2`(すべて割合・左上原点)。
    public static func cubic(_ p0: (x: Double, y: Double), _ p1: (x: Double, y: Double),
                             _ p2: (x: Double, y: Double), _ p3: (x: Double, y: Double), _ t: Double) -> (x: Double, y: Double) {
        let u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
        return (a * p0.x + b * p1.x + c * p2.x + d * p3.x, a * p0.y + b * p1.y + c * p2.y + d * p3.y)
    }

    /// 閉じたパスを直線の列へ平らにしたもの(割合・左上原点。最後の点は最初の点と重ねない)。
    /// 点が 3 未満なら空。曲線 1 本あたり `segmentsPerCurve` 分割(4〜64 に収める)。
    public func sampledPolygon(segmentsPerCurve: Int = 16) -> [(x: Double, y: Double)] {
        guard points.count >= 3 else { return [] }
        let pts = Self.normalizedPoints(points)
        let seg = min(max(segmentsPerCurve, 4), 64)
        var out: [(x: Double, y: Double)] = []
        out.reserveCapacity(pts.count * seg)
        for i in pts.indices {
            let a = pts[i], b = pts[(i + 1) % pts.count]
            for s in 0..<seg {
                out.append(Self.cubic((a.x, a.y), (a.outX, a.outY), (b.inX, b.inY), (b.x, b.y), Double(s) / Double(seg)))
            }
        }
        return out
    }

    /// 割合の点 (u, v)(左上原点)がペンの内側か。平らにした多角形の偶奇判定(レイキャスティング)。
    /// 羽根・反転は含まない、形そのものの内外。点が 3 未満なら常に false。
    public func penContains(u: Double, v: Double) -> Bool {
        let poly = sampledPolygon(segmentsPerCurve: 24)
        guard poly.count >= 3 else { return false }
        var inside = false
        var j = poly.count - 1
        for i in poly.indices {
            let a = poly[i], b = poly[j]
            if (a.y > v) != (b.y > v) {
                let xCross = (b.x - a.x) * (v - a.y) / (b.y - a.y) + a.x
                if u < xCross { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    /// パスを CI/キャンバス画素の座標(左下原点・px)で作る。描画(ラスタライズ)専用。
    public func penCGPath(canvasWidth W: Double, canvasHeight H: Double) -> CGPath {
        let path = CGMutablePath()
        guard points.count >= 3 else { return path }
        let pts = Self.normalizedPoints(points)
        func px(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x * W, y: (1 - y) * H) }
        path.move(to: px(pts[0].x, pts[0].y))
        for i in pts.indices {
            let a = pts[i], b = pts[(i + 1) % pts.count]
            path.addCurve(to: px(b.x, b.y), control1: px(a.outX, a.outY), control2: px(b.inX, b.inY))
        }
        path.closeSubpath()
        return path
    }

    enum CodingKeys: String, CodingKey { case shape, x, y, w, h, feather, invert, points }
    /// 知らないキー(新しい版が書いた項目)。そのまま書き戻す。
    public var extra: [String: JSONValue] = [:]
    static let knownKeys: Set<String> = ["shape", "x", "y", "w", "h", "feather", "invert", "points"]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ClipMask()
        self.init(shape: (try? c.decodeIfPresent(String.self, forKey: .shape)) ?? d.shape,
                  x: (try? c.decodeIfPresent(Double.self, forKey: .x)) ?? d.x,
                  y: (try? c.decodeIfPresent(Double.self, forKey: .y)) ?? d.y,
                  w: (try? c.decodeIfPresent(Double.self, forKey: .w)) ?? d.w,
                  h: (try? c.decodeIfPresent(Double.self, forKey: .h)) ?? d.h,
                  feather: (try? c.decodeIfPresent(Double.self, forKey: .feather)) ?? d.feather,
                  invert: (try? c.decodeIfPresent(Bool.self, forKey: .invert)) ?? d.invert,
                  points: (try? c.decodeIfPresent([MaskPoint].self, forKey: .points)) ?? [])
        extra = Lenient(c: try decoder.container(keyedBy: AnyKey.self), known: Self.knownKeys).extra()
    }

    /// 既定値の羽根・反転は書かない。点は、あるときだけ書く(矩形・楕円の既存ファイルと形を変えない)。
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        for (k, v) in extra { try c.encode(v, forKey: AnyKey(k)) }
        try c.encode(shape, forKey: AnyKey("shape"))
        try c.encode(x, forKey: AnyKey("x"))
        try c.encode(y, forKey: AnyKey("y"))
        try c.encode(w, forKey: AnyKey("w"))
        try c.encode(h, forKey: AnyKey("h"))
        if feather > 0 { try c.encode(feather, forKey: AnyKey("feather")) }
        if invert { try c.encode(true, forKey: AnyKey("invert")) }
        if !points.isEmpty { try c.encode(Self.normalizedPoints(points), forKey: AnyKey("points")) }
    }
}

/// マスクの画像を作って、画素にかける(UI にも Undo にも依存しない純粋な処理)。
public enum ShapeMask {
    /// キャンバス(左下原点の CI 座標)いっぱいの、白(残す)と黒(消す)のマスク。不透明(アルファ 1)にそろえる。
    public static func canvasImage(_ m: ClipMask, width W: Double, height H: Double) -> CIImage {
        let canvas = CGRect(x: 0, y: 0, width: W, height: H)
        let rx = m.x * W, ry = H - (m.y + m.h) * H           // 左下原点の矩形の左下
        let rw = m.w * W, rh = m.h * H
        let minSide = min(rw, rh)
        var shape: CIImage
        if m.shape == "pen" {
            shape = penImage(m, width: W, height: H)
        } else if m.shape == "ellipse" {
            // 単位円(半径 1)を楕円へ伸ばす。羽根は中心からの半径 (1 − 羽根) から 1 までの、白→黒の放射状の階調
            let inner = max(0, 1 - m.feather)
            let grad = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: 0, y: 0), "inputRadius0": inner, "inputRadius1": max(inner + 1e-3, 1),
                "inputColor0": CIColor(red: 1, green: 1, blue: 1), "inputColor1": CIColor(red: 0, green: 0, blue: 0),
            ])?.outputImage ?? CIImage(color: .black)
            shape = grad.transformed(by: CGAffineTransform(a: rw / 2, b: 0, c: 0, d: rh / 2, tx: rx + rw / 2, ty: ry + rh / 2))
        } else {
            // 矩形を白で塗り、羽根の分だけぼかす(ぼかしは外へも内へも広がる。境目は 50%)
            shape = CIImage(color: .white).cropped(to: CGRect(x: rx, y: ry, width: rw, height: rh))
            let sigma = m.feather * minSide * 0.25
            if sigma > 0.01 { shape = shape.applyingGaussianBlur(sigma: sigma) }
        }
        // 透明な所を黒に敷いて、輝度だけで決まる不透明なマスクにする
        var out = shape.composited(over: CIImage(color: .black).cropped(to: canvas)).cropped(to: canvas)
        if m.invert {
            out = out.applyingFilter("CIColorInvert")
        }
        return out
    }

    // MARK: ペンのラスタライズ

    // 羽根なしのペンの塗りを小さくキャッシュする(プレビュー・書き出しの毎コマ生成を避ける)。
    // キーは点列とキャンバスの大きさ。羽根のぼかしは呼び出し側で都度かける(CI の遅延評価で軽い)。
    private static let penLock = NSLock()
    nonisolated(unsafe) private static var penCache: [String: CIImage] = [:]

    static func penCacheKey(_ m: ClipMask, width W: Double, height H: Double) -> String {
        let pts = ClipMask.normalizedPoints(m.points)
            .map { [$0.x, $0.y, $0.inX, $0.inY, $0.outX, $0.outY].map { String($0) }.joined(separator: ",") }
            .joined(separator: ";")
        return "\(Int(W.rounded()))x\(Int(H.rounded()))|\(pts)"
    }

    /// ペンの塗り(白 = 中、黒 = 外、不透明)。パスをビットマップへ描いて作る。羽根は矩形と同じ作法でぼかす
    /// (基準の短い辺は、点列の外接矩形から取る)。点が 3 未満なら全面が外(黒)。
    public static func penImage(_ m: ClipMask, width W: Double, height H: Double) -> CIImage {
        let canvas = CGRect(x: 0, y: 0, width: W, height: H)
        guard m.points.count >= 3, W >= 1, H >= 1 else {
            return CIImage(color: .black).cropped(to: canvas)
        }
        let key = penCacheKey(m, width: W, height: H)
        penLock.lock()
        let hit = penCache[key]
        penLock.unlock()
        var base = hit
        if base == nil {
            base = rasterizedPen(m, width: W, height: H)
            if let base {
                penLock.lock()
                if penCache.count > 8 { penCache.removeAll() }
                penCache[key] = base
                penLock.unlock()
            }
        }
        guard var img = base else { return CIImage(color: .black).cropped(to: canvas) }
        // 羽根の基準は矩形と同じ「形の短い辺」。ペンでは点列(ハンドル込み)の外接矩形の短い辺を使う
        let xs = m.points.flatMap { pt in [pt.x, pt.inX, pt.outX] }, ys = m.points.flatMap { pt in [pt.y, pt.inY, pt.outY] }
        let bw = (xs.max()! - xs.min()!) * W, bh = (ys.max()! - ys.min()!) * H
        let sigma = m.feather * min(bw, bh) * 0.25
        if sigma > 0.01 { img = img.applyingGaussianBlur(sigma: sigma) }
        return img.cropped(to: canvas)
    }

    /// パスをグレーのビットマップへ描く(中は白、外は黒)。座標は CI と同じ左下原点で組み立てる。
    static func rasterizedPen(_ m: ClipMask, width W: Double, height H: Double) -> CIImage? {
        let iw = Int(W.rounded()), ih = Int(H.rounded())
        guard iw >= 1, ih >= 1,
              let ctx = CGContext(data: nil, width: iw, height: ih, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: iw, height: ih))
        ctx.addPath(m.penCGPath(canvasWidth: W, canvasHeight: H))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fillPath(using: .evenOdd)   // 内外判定(penContains)の偶奇規則とそろえる
        guard let cg = ctx.makeImage() else { return nil }
        return CIImage(cgImage: cg)
    }

    /// `img`(キャンバスの一部分 `origin`(左上原点・キャンバス px)から始まる作業範囲の画像)に、マスクを左上原点で重ねる。
    /// マスクの外は透明になる。
    public static func apply(_ img: CIImage, mask m: ClipMask, canvasWidth W: Double, canvasHeight H: Double, originX: Double, originY: Double) -> CIImage {
        let ext = img.extent
        let canvasMask = canvasImage(m, width: W, height: H)
        // 作業範囲の左下(CI 座標)へ動かす
        let local = canvasMask.transformed(by: CGAffineTransform(translationX: -originX, y: -(H - originY - ext.height)))
        let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: ext)
        return img.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: clear,
            kCIInputMaskImageKey: local.cropped(to: ext),
        ]).cropped(to: ext)
    }
}
