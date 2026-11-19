import Foundation

/// HSL の範囲選択(色相・彩度・輝度の 3 要素の重み 0〜1)。
///
/// 補正(`HSLSecondary`)から切り離した独立部品で、将来の「HSL マスキング」でもそのまま使える。
/// 重みは色相・彩度・輝度それぞれの滑らかな重みの積。内側は 1、外側は 0、端から feather の幅で smoothstep により遷移する。
public struct HSLSelection: Equatable, Sendable {
    /// 色相の中心(度、0..<360)。
    public var hueCenter: Double
    /// 色相の幅(度、0〜360)。360 以上なら色相によらず常に 1。
    public var hueWidth: Double
    /// 色相のぼかし(度、0〜180)。0 は硬い段差。
    public var hueFeather: Double
    public var satMin: Double
    public var satMax: Double
    public var satFeather: Double
    public var lumMin: Double
    public var lumMax: Double
    public var lumFeather: Double

    public init(hueCenter: Double = 0, hueWidth: Double = 90, hueFeather: Double = 45,
                satMin: Double = 0, satMax: Double = 1, satFeather: Double = 0.1,
                lumMin: Double = 0, lumMax: Double = 1, lumFeather: Double = 0.1) {
        self.hueCenter = hueCenter; self.hueWidth = hueWidth; self.hueFeather = hueFeather
        self.satMin = satMin; self.satMax = satMax; self.satFeather = satFeather
        self.lumMin = lumMin; self.lumMax = lumMax; self.lumFeather = lumFeather
    }

    /// 3 次のなめらかな階段(0 → 1)。
    static func smoothstep(_ t: Double) -> Double {
        let t = min(max(t, 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// 色相の重み(円周距離で判定)。
    func hueWeight(_ hueDegrees: Double) -> Double {
        if hueWidth >= 360 { return 1 }
        var c = hueCenter.isFinite ? hueCenter.truncatingRemainder(dividingBy: 360) : 0
        if c < 0 { c += 360 }
        var d = abs((hueDegrees.isFinite ? hueDegrees : 0).truncatingRemainder(dividingBy: 360) - c)
        if d > 180 { d = 360 - d }
        let half = max(hueWidth, 0) / 2
        if d <= half { return 1 }
        if hueFeather <= 0 { return 0 }
        return 1 - Self.smoothstep((d - half) / hueFeather)
    }

    /// [lo, hi] の内側 1、外側 0、端から feather 分は smoothstep で遷移する重み。
    static func rangeWeight(_ v: Double, lo: Double, hi: Double, feather: Double) -> Double {
        if v >= lo && v <= hi { return 1 }
        if feather <= 0 { return 0 }
        let d = v < lo ? lo - v : v - hi
        return 1 - smoothstep(d / feather)
    }

    /// 選択の重み(0〜1)。色相は度(円周)、彩度・輝度は 0〜1。非有限の入力は 0 として扱う。
    public func weight(hueDegrees: Double, saturation: Double, lightness: Double) -> Double {
        let s = ColorHSL.clamp01(saturation), l = ColorHSL.clamp01(lightness)
        let w = hueWeight(hueDegrees)
            * Self.rangeWeight(s, lo: satMin, hi: satMax, feather: satFeather)
            * Self.rangeWeight(l, lo: lumMin, hi: lumMax, feather: lumFeather)
        return min(max(w, 0), 1)
    }

    /// RGB(0〜1)から HSL を求めて重みを返す。
    public func weight(r: Double, g: Double, b: Double) -> Double {
        let c = ColorHSL.hsl(r: r, g: g, b: b)
        return weight(hueDegrees: c.h * 360, saturation: c.s, lightness: c.l)
    }

    /// 選択の重みをそのまま (w, w, w, 1) のグレースケールにした CIColorCube 用データ
    /// (Float の RGBA × dimension³、赤が一番速く動く並び)。将来のマスク画像生成(HSL マスキング)の土台。
    public static func maskCubeData(selection: HSLSelection, dimension: Int = 33) -> Data {
        let n = max(dimension, 2)
        var floats = [Float]()
        floats.reserveCapacity(n * n * n * 4)
        let step = 1 / Double(n - 1)
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let w = Float(selection.weight(r: Double(r) * step, g: Double(g) * step, b: Double(b) * step))
                    floats.append(w); floats.append(w); floats.append(w); floats.append(1)
                }
            }
        }
        return floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
