import Foundation
import CoreGraphics

/// 表示用サンプリングの間引き幅を決める共通部品(ベクトルスコープと RGB パレードで共用)。
/// 全画素ではなく上限サンプル数に収まるよう、縦横同じ歩幅で等間隔に拾う。
enum ScopeSampling {
    /// `width × height` が `maxSamples` を超えるときの歩幅(1 = 間引きなし)。
    static func stride(width: Int, height: Int, maxSamples: Int) -> Int {
        guard width > 0, height > 0, maxSamples > 0 else { return 1 }
        let total = Double(width) * Double(height)
        guard total > Double(maxSamples) else { return 1 }
        return max(1, Int(ceil(sqrt(total / Double(maxSamples)))))
    }
}

/// CGImage を RGBA8(左上から、1 画素 4 バイト)へ読み直す。読めなければ nil。
enum ScopePixels {
    static func rgba(_ image: CGImage) -> (bytes: [UInt8], width: Int, height: Int)? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? (buf, w, h) : nil
    }
}

/// ベクトルスコープ: 画素の色を色差(Cb・Cr)の平面に落とした分布。Premiere Pro の Lumetri ベクトルスコープ相当。
/// 値は表示用の sRGB 符号化値(0〜255)が前提で、輝度・色差は Rec.709 係数で作る:
///   Y  = 0.2126 R + 0.7152 G + 0.0722 B        (R・G・B は 0〜1)
///   Cb = (B − Y) / (2 × (1 − 0.0722))          (およそ −0.5〜+0.5)
///   Cr = (R − Y) / (2 × (1 − 0.2126))          (およそ −0.5〜+0.5)
/// 中心が無彩色、中心からの向きが色相、距離が彩度に対応する。原色の純色は半径およそ 0.5〜0.6 の六角形の頂点に落ちる。
/// 計算は表示用に間引く(既定で最大 262,144 サンプル)。間引いても分布の形は保たれるが、ごく少数の画素しかない色は落ちることがある。
public enum VectorScope {
    /// 密度グリッドの一辺(128 × 128 マス)。
    public static let gridSize = 128
    /// 既定の最大サンプル数。
    public static let defaultMaxSamples = 262_144
    /// スキントーンラインの角度(度、Cb を x 軸・Cr を y 軸とした平面、反時計回り)。
    /// 肌色の代表値(例: RGB 200・150・120 で約 128°、180・120・90 で約 125°)の中央を取った目安で、厳密な規格値ではない。
    public static let skinToneAngleDegrees: Double = 127

    /// 1 画素の色差。`cb` が横軸、`cr` が縦軸(上が正)。
    public struct Chroma: Equatable {
        public var cb: Double
        public var cr: Double
        public init(cb: Double, cr: Double) { self.cb = cb; self.cr = cr }
        /// 中心からの角度(度、−180〜180)。
        public var angleDegrees: Double { atan2(cr, cb) * 180 / .pi }
        /// 中心からの距離(彩度の目安)。純色でおよそ 0.5〜0.6、無彩色で 0。
        public var radius: Double { hypot(cb, cr) }
        /// 表示用の正規化座標(−1〜1 目安。純色の一部は 1 をわずかに超える)。x = Cb × 2、y = Cr × 2。
        public var normalizedX: Double { cb * 2 }
        public var normalizedY: Double { cr * 2 }
    }

    /// sRGB 値(0〜255)から色差を作る。
    public static func chroma(red r: UInt8, green g: UInt8, blue b: UInt8) -> Chroma {
        let rd = Double(r) / 255, gd = Double(g) / 255, bd = Double(b) / 255
        let y = 0.2126 * rd + 0.7152 * gd + 0.0722 * bd
        return Chroma(cb: (bd - y) / (2 * (1 - 0.0722)), cr: (rd - y) / (2 * (1 - 0.2126)))
    }

    /// 目安表示用の純色の位置(赤・緑・青・シアン・マゼンタ・黄)。
    public struct Target: Equatable {
        public var name: String
        public var chroma: Chroma
    }

    public static let targets: [Target] = [
        Target(name: "R", chroma: chroma(red: 255, green: 0, blue: 0)),
        Target(name: "M", chroma: chroma(red: 255, green: 0, blue: 255)),
        Target(name: "B", chroma: chroma(red: 0, green: 0, blue: 255)),
        Target(name: "C", chroma: chroma(red: 0, green: 255, blue: 255)),
        Target(name: "G", chroma: chroma(red: 0, green: 255, blue: 0)),
        Target(name: "Y", chroma: chroma(red: 255, green: 255, blue: 0)),
    ]

    /// スキントーンラインの終点(正規化座標、中心から半径 0.9)。UI が中心から線を引くための目安。
    public static var skinToneLineEnd: (x: Double, y: Double) {
        let rad = skinToneAngleDegrees * .pi / 180
        return (cos(rad) * 0.9, sin(rad) * 0.9)
    }

    /// 正規化座標(−1〜1)からグリッドのマス番号(0〜gridSize−1)を返す。範囲外は端に寄せる。
    /// 行は上が Cr 正(0 行目が上)になるよう反転する。
    public static func gridCell(normalizedX x: Double, normalizedY y: Double, size: Int = gridSize) -> (column: Int, row: Int) {
        let s = max(1, size)
        let col = min(s - 1, max(0, Int((x + 1) / 2 * Double(s))))
        let row = min(s - 1, max(0, Int((1 - y) / 2 * Double(s))))
        return (col, row)
    }

    public struct Result: Equatable {
        /// 密度グリッド(`grid[row * size + column]`、行 0 が上 = Cr 正)。
        public var grid: [Int]
        public var size: Int
        /// 実際に数えた画素数(間引き後)。
        public var sampledCount: Int
        /// 元画像の画素数。
        public var totalCount: Int
        /// 間引きの歩幅(1 = 全画素)。
        public var stride: Int
        public var width: Int
        public var height: Int
        /// 最も密度の高いマスの画素数(表示の濃さ計算用)。
        public var maxCount: Int { grid.max() ?? 0 }
    }

    /// 画像から計算する(RGBA8 で読み直す)。読めなければ nil。
    public static func analyze(_ image: CGImage, maxSamples: Int = defaultMaxSamples) -> Result? {
        guard let px = ScopePixels.rgba(image) else { return nil }
        return analyze(rgba: px.bytes, width: px.width, height: px.height, maxSamples: maxSamples)
    }

    /// RGBA8(左上から、1 画素 4 バイト)から計算する。`rgba` の長さが足りなければ nil。
    public static func analyze(rgba: [UInt8], width w: Int, height h: Int, maxSamples: Int = defaultMaxSamples) -> Result? {
        guard w > 0, h > 0, rgba.count >= w * h * 4 else { return nil }
        let stride = ScopeSampling.stride(width: w, height: h, maxSamples: maxSamples)
        let size = gridSize
        var grid = [Int](repeating: 0, count: size * size)
        var sampled = 0
        rgba.withUnsafeBufferPointer { p in
            var y = 0
            while y < h {
                var x = 0
                while x < w {
                    let i = (y * w + x) * 4
                    let c = chroma(red: p[i], green: p[i + 1], blue: p[i + 2])
                    let cell = gridCell(normalizedX: c.normalizedX, normalizedY: c.normalizedY, size: size)
                    grid[cell.row * size + cell.column] += 1
                    sampled += 1
                    x += stride
                }
                y += stride
            }
        }
        return Result(grid: grid, size: size, sampledCount: sampled, totalCount: w * h, stride: stride, width: w, height: h)
    }

    /// 1 マスの濃さ(0〜1)。既存スコープと同じ対数圧縮(`VideoScope.intensity`)を使う。
    public static func intensity(_ count: Int, max maxCount: Int) -> Double {
        VideoScope.intensity(count, max: maxCount)
    }
}
