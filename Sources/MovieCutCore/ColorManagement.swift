import Foundation
import CoreImage

/// クリップの入力色空間(撮影時のガンマ+色域)。作業空間は Rec.709 固定で、Rec.709 以外は描画の頭で Rec.709 へ変換する。
/// 文字列(rawValue)がそのままプロジェクトファイルに保存される。
public enum InputColorSpace: String, CaseIterable, Codable, Sendable {
    case rec709 = "rec709"
    case sLog3 = "slog3"
    case vLog = "vlog"
    case hlg = "hlg"
    case rec2020 = "rec2020"

    public var displayName: String {
        switch self {
        case .rec709: return "Rec.709（標準）"
        case .sLog3: return "S-Log3 / S-Gamut3.Cine"
        case .vLog: return "V-Log / V-Gamut"
        case .hlg: return "HLG / Rec.2020"
        case .rec2020: return "Rec.2020（ガンマ）"
        }
    }
}

/// 色変換の数式(すべて純粋関数。画素もファイルも触らない)と、それを 3D LUT に焼いて画像へかける処理。
///
/// 流れ: 符号化値(0...1) →(逆伝達関数)→ シーン/表示の線形値 →(色域の 3x3 行列)→ Rec.709 線形 →(Rec.709 OETF)→ 符号化値。
/// Rec.709 の符号化は ITU-R BT.709 の OETF。Rec.709 の動画はアプリ内で「符号化値のまま」扱うため、その値と対称になる。
public enum ColorManagement {
    public typealias RGB = (r: Double, g: Double, b: Double)
    public typealias Matrix3 = [[Double]]

    // MARK: 伝達関数(符号化値 → 線形)

    /// Sony S-Log3 の逆変換。符号化値 0...1 → 線形反射率(18% グレー = 0.18)。
    public static func sLog3ToLinear(_ x: Double) -> Double {
        if x >= 171.2102946929 / 1023.0 {
            return pow(10, (x * 1023.0 - 420.0) / 261.5) * (0.18 + 0.01) - 0.01
        }
        return (x * 1023.0 - 95.0) * 0.01125000 / (171.2102946929 - 95.0)
    }
    public static func linearToSLog3(_ y: Double) -> Double {
        if y >= 0.01125000 {
            return (420.0 + log10((y + 0.01) / (0.18 + 0.01)) * 261.5) / 1023.0
        }
        return (y * (171.2102946929 - 95.0) / 0.01125000 + 95.0) / 1023.0
    }

    /// Panasonic V-Log の逆変換。符号化値 0...1 → 線形反射率(18% グレー = 0.18)。
    public static func vLogToLinear(_ x: Double) -> Double {
        let b = 0.00873, c = 0.241514, d = 0.598206
        if x < 0.181 { return (x - 0.125) / 5.6 }
        return pow(10, (x - d) / c) - b
    }
    public static func linearToVLog(_ y: Double) -> Double {
        let b = 0.00873, c = 0.241514, d = 0.598206
        if y < 0.01 { return 5.6 * y + 0.125 }
        return c * log10(y + b) + d
    }

    /// ARIB STD-B67 HLG の逆 OETF。符号化値 0...1 → シーン線形(1.0 = ピーク)。
    public static func hlgToSceneLinear(_ x: Double) -> Double {
        let a = 0.17883277, b = 0.28466892, c = 0.55991073
        if x <= 0.5 { return x * x / 3.0 }
        return (exp((x - c) / a) + b) / 12.0
    }
    /// HLG の基準白(信号 0.75 = 拡散白 約 203 nit)のシーン線形値。SDR の白(1.0)に合わせるための分母。
    public static let hlgReferenceWhite: Double = hlgToSceneLinear(0.75)
    /// HLG を SDR(Rec.709)へ: OOTF(システムガンマ)は省略し、基準白が白になるよう定数倍するだけの簡易版。
    public static func hlgToSDRLinear(_ x: Double) -> Double { hlgToSceneLinear(x) / hlgReferenceWhite }

    /// ITU-R BT.709 / BT.2020 の OETF(符号化 → 線形 / 線形 → 符号化)。
    public static func bt709ToLinear(_ v: Double) -> Double {
        v < 0.081 ? v / 4.5 : pow((v + 0.099) / 1.099, 1.0 / 0.45)
    }
    public static func linearToBT709(_ l: Double) -> Double {
        l < 0.018 ? 4.5 * l : 1.099 * pow(l, 0.45) - 0.099
    }

    // MARK: 色域(原色の xy 色度 → 3x3 行列)

    struct Primaries { var r: (Double, Double), g: (Double, Double), b: (Double, Double), w: (Double, Double) }
    static let d65 = (0.3127, 0.3290)
    static let rec709Primaries = Primaries(r: (0.640, 0.330), g: (0.300, 0.600), b: (0.150, 0.060), w: d65)
    static let rec2020Primaries = Primaries(r: (0.708, 0.292), g: (0.170, 0.797), b: (0.131, 0.046), w: d65)
    static let sGamut3CinePrimaries = Primaries(r: (0.766, 0.275), g: (0.225, 0.800), b: (0.089, -0.087), w: d65)
    static let vGamutPrimaries = Primaries(r: (0.730, 0.280), g: (0.165, 0.840), b: (0.100, -0.030), w: d65)

    static func mul(_ a: Matrix3, _ b: Matrix3) -> Matrix3 {
        (0..<3).map { i in (0..<3).map { j in (0..<3).reduce(0.0) { $0 + a[i][$1] * b[$1][j] } } }
    }
    public static func apply(_ m: Matrix3, _ v: RGB) -> RGB {
        (m[0][0] * v.r + m[0][1] * v.g + m[0][2] * v.b,
         m[1][0] * v.r + m[1][1] * v.g + m[1][2] * v.b,
         m[2][0] * v.r + m[2][1] * v.g + m[2][2] * v.b)
    }
    public static func inverse(_ m: Matrix3) -> Matrix3 {
        let a = m[0][0], b = m[0][1], c = m[0][2], d = m[1][0], e = m[1][1], f = m[1][2], g = m[2][0], h = m[2][1], i = m[2][2]
        let A = e * i - f * h, B = -(d * i - f * g), C = d * h - e * g
        let det = a * A + b * B + c * C
        guard abs(det) > 1e-12 else { return [[1, 0, 0], [0, 1, 0], [0, 0, 1]] }
        return [[A / det, -(b * i - c * h) / det, (b * f - c * e) / det],
                [B / det, (a * i - c * g) / det, -(a * f - c * d) / det],
                [C / det, -(a * h - b * g) / det, (a * e - b * d) / det]]
    }

    /// 原色と白色点から、線形 RGB → CIE XYZ の行列。
    static func rgbToXYZ(_ p: Primaries) -> Matrix3 {
        func xyz(_ c: (Double, Double)) -> [Double] { [c.0 / c.1, 1, (1 - c.0 - c.1) / c.1] }
        let r = xyz(p.r), g = xyz(p.g), b = xyz(p.b), w = xyz(p.w)
        let prim: Matrix3 = [[r[0], g[0], b[0]], [r[1], g[1], b[1]], [r[2], g[2], b[2]]]
        let s = apply(inverse(prim), (w[0], w[1], w[2]))
        let sv = [s.r, s.g, s.b]
        return (0..<3).map { i in [prim[i][0] * sv[0], prim[i][1] * sv[1], prim[i][2] * sv[2]] }
    }

    /// その入力色域の線形 RGB → Rec.709 線形 RGB の行列(両方 D65 なので色順応は不要)。Rec.709 は単位行列。
    public static func gamutToRec709Matrix(_ cs: InputColorSpace) -> Matrix3 {
        let src: Primaries
        switch cs {
        case .rec709: return [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
        case .sLog3: src = sGamut3CinePrimaries
        case .vLog: src = vGamutPrimaries
        case .hlg, .rec2020: src = rec2020Primaries
        }
        return mul(inverse(rgbToXYZ(rec709Primaries)), rgbToXYZ(src))
    }

    // MARK: 変換本体

    /// 入力色空間の符号化値 → 線形値(色域変換前)。
    static func decodeToLinear(_ cs: InputColorSpace, _ v: Double) -> Double {
        switch cs {
        case .rec709, .rec2020: return bt709ToLinear(v)
        case .sLog3: return sLog3ToLinear(v)
        case .vLog: return vLogToLinear(v)
        case .hlg: return hlgToSDRLinear(v)
        }
    }

    /// 入力色空間の符号化値(0...1)→ Rec.709 の符号化値(0...1・範囲外は丸める)。Rec.709 は恒等。
    public static func convertToRec709(_ rgb: RGB, from cs: InputColorSpace) -> RGB {
        if cs == .rec709 { return rgb }
        let lin: RGB = (decodeToLinear(cs, rgb.r), decodeToLinear(cs, rgb.g), decodeToLinear(cs, rgb.b))
        let o = apply(gamutToRec709Matrix(cs), lin)
        func enc(_ l: Double) -> Double { min(max(linearToBT709(max(l, 0)), 0), 1) }
        return (enc(o.r), enc(o.g), enc(o.b))
    }

    // MARK: 3D LUT への焼き込みと適用

    public static let lutSize = 33

    /// 変換を焼いた立方体(CIColorCube 用。赤が最も速く変わる RGBA float)。
    public static func cubeData(for cs: InputColorSpace, size n: Int = lutSize) -> Data {
        var out = [Float](); out.reserveCapacity(n * n * n * 4)
        for b in 0..<n { for g in 0..<n { for r in 0..<n {
            let o = convertToRec709((Double(r) / Double(n - 1), Double(g) / Double(n - 1), Double(b) / Double(n - 1)), from: cs)
            out.append(Float(o.r)); out.append(Float(o.g)); out.append(Float(o.b)); out.append(1)
        } } }
        return out.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static let cache = LockedCubeCache()
    private final class LockedCubeCache: @unchecked Sendable {
        private let lock = NSLock()
        private var cubes: [InputColorSpace: Data] = [:]
        func data(_ cs: InputColorSpace) -> Data {
            lock.lock(); defer { lock.unlock() }
            if let d = cubes[cs] { return d }
            let d = ColorManagement.cubeData(for: cs)
            cubes[cs] = d
            return d
        }
    }
    private static let sRGBSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    /// 既存の LUT(.cube)と同じ CIColorCubeWithColorSpace で、焼いた立方体をかける。Rec.709 は何もしない(元の画像をそのまま返す)。
    public static func apply(_ img: CIImage, from cs: InputColorSpace) -> CIImage {
        guard cs != .rec709 else { return img }
        return img.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": lutSize, "inputCubeData": cache.data(cs), "inputColorSpace": sRGBSpace,
        ]).cropped(to: img.extent)
    }
}
