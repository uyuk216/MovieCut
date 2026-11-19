import Foundation

/// HSL セカンダリ補正の量。
public struct HSLCorrection: Equatable, Sendable {
    /// 色相シフト(度)。
    public var hueShift: Double
    /// 彩度の倍率。
    public var satScale: Double
    /// 露出(EV)。
    public var exposureEV: Double
    /// 全体の混ぜ具合(0〜1)。
    public var strength: Double

    public init(hueShift: Double = 0, satScale: Double = 1, exposureEV: Double = 0, strength: Double = 1) {
        self.hueShift = hueShift; self.satScale = satScale; self.exposureEV = exposureEV; self.strength = strength
    }

    /// 何もしない補正か(強さがほぼ 0、またはシフト 0 かつ倍率 1 かつ EV 0)。
    public var isIdentity: Bool {
        let eps = 1e-6
        return strength <= eps || (abs(hueShift) <= eps && abs(satScale - 1) <= eps && abs(exposureEV) <= eps)
    }
}

/// HSL セカンダリ補正。`HSLSelection` で選んだ範囲の色にだけ、色相・彩度・露出の補正をかける。
///
/// 補正後の色 = HSL で(色相 += シフト、彩度 *= 倍率)→ RGB に戻す → 露出 2^EV 倍(クランプ)。
/// 出力 = 元 × (1 − w) + 補正後 × w(w = 選択の重み × 強さ)。
public enum HSLSecondary {
    /// 3D 表の 1 辺の画素数(33³ = 35937 点)。
    public static let cubeDimension = 33

    /// 1 点の補正(0〜1 の RGB → 0〜1 の RGB)。重みがほぼ 0 なら入力をそのまま返す。
    public static func corrected(r: Double, g: Double, b: Double,
                                 selection: HSLSelection, correction: HSLCorrection) -> (r: Double, g: Double, b: Double) {
        let strength = ColorHSL.clamp01(correction.strength)
        let w = selection.weight(r: r, g: g, b: b) * strength
        if w <= 1e-9 { return (r, g, b) }
        let c = ColorHSL.hsl(r: r, g: g, b: b)
        let s = min(max(c.s * correction.satScale, 0), 1)
        let rgb = ColorHSL.rgb(h: c.h + correction.hueShift / 360, s: s, l: c.l)
        let gain = pow(2, correction.exposureEV)
        let cr = ColorHSL.clamp01(rgb.r * gain), cg = ColorHSL.clamp01(rgb.g * gain), cb = ColorHSL.clamp01(rgb.b * gain)
        return (r * (1 - w) + cr * w, g * (1 - w) + cg * w, b * (1 - w) + cb * w)
    }

    /// CIColorCube 用のデータ(Float の RGBA × cubeDimension³、赤が一番速く動く並び)。
    public static func cubeData(selection: HSLSelection, correction: HSLCorrection) -> Data {
        let n = cubeDimension
        var floats = [Float]()
        floats.reserveCapacity(n * n * n * 4)
        let step = 1 / Double(n - 1)
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let m = corrected(r: Double(r) * step, g: Double(g) * step, b: Double(b) * step,
                                      selection: selection, correction: correction)
                    floats.append(Float(m.r)); floats.append(Float(m.g)); floats.append(Float(m.b)); floats.append(1)
                }
            }
        }
        return floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// 引数値(キー → 値)から範囲選択を復元する。キーは hueCenter / hueWidth / hueFeather / satMin / satMax / satFeather / lumMin / lumMax / lumFeather。
    public static func selection(from values: (String) -> Double) -> HSLSelection {
        HSLSelection(hueCenter: values("hueCenter"), hueWidth: values("hueWidth"), hueFeather: values("hueFeather"),
                     satMin: values("satMin"), satMax: values("satMax"), satFeather: values("satFeather"),
                     lumMin: values("lumMin"), lumMax: values("lumMax"), lumFeather: values("lumFeather"))
    }

    /// 引数値から補正量を復元する。キーは hueShift / satScale / exposure(→ exposureEV) / strength。
    public static func correction(from values: (String) -> Double) -> HSLCorrection {
        HSLCorrection(hueShift: values("hueShift"), satScale: values("satScale"),
                      exposureEV: values("exposure"), strength: values("strength"))
    }
}
