import Foundation
import CoreGraphics

/// 映像スコープ(ヒストグラムと波形)。1 コマのピクセルから計算する純粋な関数。画面には出さず、結果の配列を返す。
/// 値は表示のための sRGB の符号化値(0〜255)で、輝度は Rec.709 の係数(0.2126 R + 0.7152 G + 0.0722 B)。
public enum VideoScope {
    public static let levels = 256

    public struct Result: Equatable {
        /// 各 256 段のヒストグラム(画素数)。
        public var red: [Int]
        public var green: [Int]
        public var blue: [Int]
        public var luma: [Int]
        /// 波形: 横 `columns` 段 × 縦 256 段の画素数(`waveform[col * 256 + level]`)。
        public var columns: Int
        public var waveform: [Int]
        public var width: Int
        public var height: Int
    }

    /// 画像から計算する(RGBA8 で読み直す)。読めなければ nil。
    public static func analyze(_ image: CGImage, columns: Int = 256) -> Result? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        return analyze(rgba: buf, width: w, height: h, columns: columns)
    }

    /// RGBA8(左上から、1 画素 4 バイト、行の長さは width × 4)から計算する。`rgba` の長さが足りなければ nil。
    public static func analyze(rgba: [UInt8], width w: Int, height h: Int, columns requested: Int = 256) -> Result? {
        guard w > 0, h > 0, rgba.count >= w * h * 4 else { return nil }
        let cols = max(1, min(requested, w))
        var r = [Int](repeating: 0, count: levels), g = r, b = r, l = r
        var wf = [Int](repeating: 0, count: cols * levels)
        rgba.withUnsafeBufferPointer { p in
            for y in 0..<h {
                for x in 0..<w {
                    let i = (y * w + x) * 4
                    let rv = Int(p[i]), gv = Int(p[i + 1]), bv = Int(p[i + 2])
                    let lv = min(levels - 1, Int((0.2126 * Double(rv) + 0.7152 * Double(gv) + 0.0722 * Double(bv)).rounded()))
                    r[rv] += 1; g[gv] += 1; b[bv] += 1; l[lv] += 1
                    let c = x * cols / w
                    wf[c * levels + lv] += 1
                }
            }
        }
        return Result(red: r, green: g, blue: b, luma: l, columns: cols, waveform: wf, width: w, height: h)
    }

    /// 波形の 1 マスの濃さ(0〜1)。対数で潰して、少ない画素も見えるようにする。
    public static func intensity(_ count: Int, max maxCount: Int) -> Double {
        guard count > 0, maxCount > 0 else { return 0 }
        return min(1, log(1 + Double(count)) / log(1 + Double(maxCount)))
    }
}
