import Foundation
import CoreGraphics
import CoreImage

/// クリップの形のマスク。キャンバスの中の矩形か楕円(0〜1・左上原点)で、中を残し外を透明にする(反転・羽根付き)。
/// エフェクトの後にかける(`Renderer`)。省いたとき(nil)は何もしない。ファイルでは、`shape` 以外は既定値のときは書かない。
public struct ClipMask: Codable, Equatable, Sendable {
    public static let shapes = ["rect", "ellipse"]
    /// 形: "rect"(矩形)か "ellipse"(楕円)。
    public var shape: String
    /// 位置・大きさ(キャンバスの幅・高さに対する割合・左上原点)。
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double
    /// 羽根(0 = くっきり、1 = 短い辺の 1/4 ぶんのなだらかさ)。
    public var feather: Double
    /// true で外を残し、中を透明にする。
    public var invert: Bool

    public init(shape: String = "rect", x: Double = 0.25, y: Double = 0.25, w: Double = 0.5, h: Double = 0.5, feather: Double = 0, invert: Bool = false) {
        self.shape = Self.shapes.contains(shape) ? shape : "rect"
        self.x = Self.clampUnit(x); self.y = Self.clampUnit(y)
        self.w = min(max(w, 0.01), 1); self.h = min(max(h, 0.01), 1)
        self.feather = Self.clampUnit(feather); self.invert = invert
    }

    static func clampUnit(_ v: Double) -> Double { v.isFinite ? min(max(v, 0), 1) : 0 }

    enum CodingKeys: String, CodingKey { case shape, x, y, w, h, feather, invert }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ClipMask()
        self.init(shape: (try? c.decodeIfPresent(String.self, forKey: .shape)) ?? d.shape,
                  x: (try? c.decodeIfPresent(Double.self, forKey: .x)) ?? d.x,
                  y: (try? c.decodeIfPresent(Double.self, forKey: .y)) ?? d.y,
                  w: (try? c.decodeIfPresent(Double.self, forKey: .w)) ?? d.w,
                  h: (try? c.decodeIfPresent(Double.self, forKey: .h)) ?? d.h,
                  feather: (try? c.decodeIfPresent(Double.self, forKey: .feather)) ?? d.feather,
                  invert: (try? c.decodeIfPresent(Bool.self, forKey: .invert)) ?? d.invert)
    }

    /// 既定値の羽根・反転は書かない。
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(shape, forKey: .shape)
        try c.encode(x, forKey: .x)
        try c.encode(y, forKey: .y)
        try c.encode(w, forKey: .w)
        try c.encode(h, forKey: .h)
        if feather > 0 { try c.encode(feather, forKey: .feather) }
        if invert { try c.encode(true, forKey: .invert) }
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
        if m.shape == "ellipse" {
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
