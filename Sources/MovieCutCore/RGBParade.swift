import Foundation
import CoreGraphics

/// RGB パレード: 波形モニターを R・G・B の 3 チャンネルに分け、横位置ごとに各チャンネルの明るさを並べて出す。
/// Premiere Pro の Lumetri「RGB パレード」相当。値は表示用の sRGB 符号化値(0〜255)。
/// 既存の波形(`VideoScope` の輝度波形)とは別計算で、そちらの挙動は変えない。
/// 計算は表示用に間引く(既定で最大 262,144 サンプル、縦横同じ歩幅)。間引くと 1 列あたりの画素数は減るが、
/// 列ごとの上下の広がり(最小〜最大の形)は概ね保たれる。ごく薄い線状の色は落ちることがある。
public enum RGBParade {
    public static let levels = 256
    /// 既定の最大サンプル数。
    public static let defaultMaxSamples = 262_144

    public struct Result: Equatable {
        /// チャンネル別波形: 横 `columns` 段 × 縦 256 段の画素数(`red[col * 256 + level]` など)。3 本は互いに独立に数える。
        public var red: [Int]
        public var green: [Int]
        public var blue: [Int]
        public var columns: Int
        /// 実際に数えた画素数(間引き後、3 チャンネル共通)。
        public var sampledCount: Int
        /// 元画像の画素数。
        public var totalCount: Int
        /// 間引きの歩幅(1 = 全画素)。
        public var stride: Int
        public var width: Int
        public var height: Int
    }

    /// 画像から計算する(RGBA8 で読み直す)。読めなければ nil。
    public static func analyze(_ image: CGImage, columns: Int = 256, maxSamples: Int = defaultMaxSamples) -> Result? {
        guard let px = ScopePixels.rgba(image) else { return nil }
        return analyze(rgba: px.bytes, width: px.width, height: px.height, columns: columns, maxSamples: maxSamples)
    }

    /// RGBA8(左上から、1 画素 4 バイト)から計算する。`rgba` の長さが足りなければ nil。
    public static func analyze(rgba: [UInt8], width w: Int, height h: Int, columns requested: Int = 256, maxSamples: Int = defaultMaxSamples) -> Result? {
        guard w > 0, h > 0, w <= (rgba.count / 4) / h else { return nil }
        let cols = max(1, min(requested, w))
        let stride = ScopeSampling.stride(width: w, height: h, maxSamples: maxSamples)
        var r = [Int](repeating: 0, count: cols * levels)
        var g = r, b = r
        var sampled = 0
        rgba.withUnsafeBufferPointer { p in
            var y = 0
            while y < h {
                var x = 0
                while x < w {
                    let i = (y * w + x) * 4
                    let c = x * cols / w
                    r[c * levels + Int(p[i])] += 1
                    g[c * levels + Int(p[i + 1])] += 1
                    b[c * levels + Int(p[i + 2])] += 1
                    sampled += 1
                    x += stride
                }
                y += stride
            }
        }
        return Result(red: r, green: g, blue: b, columns: cols, sampledCount: sampled, totalCount: w * h, stride: stride, width: w, height: h)
    }

    /// 1 マスの濃さ(0〜1)。既存スコープと同じ対数圧縮(`VideoScope.intensity`)を使う。
    public static func intensity(_ count: Int, max maxCount: Int) -> Double {
        VideoScope.intensity(count, max: maxCount)
    }
}
