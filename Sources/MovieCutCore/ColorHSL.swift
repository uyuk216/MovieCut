import Foundation

/// RGB と HSL の相互変換(標準的な HSL。Premiere の HSL セカンダリと同じ色空間)。
///
/// 色相 h は 0..<1(1 周 = 360°)、彩度 s と輝度 l は 0...1。入力は範囲内にクランプし、非有限(NaN・無限大)は 0 として扱う。
public enum ColorHSL {
    /// 0...1 にクランプする(非有限は 0)。
    static func clamp01(_ v: Double) -> Double {
        v.isFinite ? min(max(v, 0), 1) : 0
    }

    /// RGB(0〜1) → HSL。無彩色の色相は 0。
    public static func hsl(r: Double, g: Double, b: Double) -> (h: Double, s: Double, l: Double) {
        let r = clamp01(r), g = clamp01(g), b = clamp01(b)
        let mx = max(r, max(g, b)), mn = min(r, min(g, b))
        let l = (mx + mn) / 2
        let d = mx - mn
        if d <= 0 { return (0, 0, l) }
        let s = min(max(d / (1 - abs(2 * l - 1)), 0), 1)
        var h: Double
        if mx == r {
            h = (g - b) / d
            if h < 0 { h += 6 }
        } else if mx == g {
            h = (b - r) / d + 2
        } else {
            h = (r - g) / d + 4
        }
        h /= 6
        if h >= 1 { h -= 1 }
        return (h, s, l)
    }

    /// HSL → RGB(0〜1)。色相は循環で正規化し、s / l はクランプする。
    public static func rgb(h: Double, s: Double, l: Double) -> (r: Double, g: Double, b: Double) {
        let h0 = h.isFinite ? h : 0
        var hh = h0 - floor(h0)
        if hh >= 1 { hh = 0 }
        let s = clamp01(s), l = clamp01(l)
        let c = (1 - abs(2 * l - 1)) * s
        let hp = hh * 6
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        let m = l - c / 2
        let (r1, g1, b1): (Double, Double, Double)
        switch Int(hp) {
        case 0: (r1, g1, b1) = (c, x, 0)
        case 1: (r1, g1, b1) = (x, c, 0)
        case 2: (r1, g1, b1) = (0, c, x)
        case 3: (r1, g1, b1) = (0, x, c)
        case 4: (r1, g1, b1) = (x, 0, c)
        default: (r1, g1, b1) = (c, 0, x)
        }
        return (clamp01(r1 + m), clamp01(g1 + m), clamp01(b1 + m))
    }
}
