import Foundation
import CoreGraphics
import CoreImage

/// 自動ホワイトバランス(グレーワールド法)。コマの平均色が灰色になるように、`whiteBalance` エフェクトの
/// 色温度(`temperature`)とティント(`tint`)を決める。計算は純粋な関数で、描画(Core Image)には依存しない。
///
/// 手順: (1) 効果を外した 1 コマを小さく描く(`measurementProject`)(2) 白飛び・黒つぶれの画素を除いた平均をsRGB 符号化値で求める
/// (`averageColor`)(3) 赤/青の比と緑の偏りから、`CITemperatureAndTint` の効き方の実測表を逆に引いて値を決める(`estimate`)。
public enum AutoWhiteBalance {
    public struct Result: Equatable, Sendable {
        public var temperature: Double
        public var tint: Double
        /// 何も直さなくてよい(両方 0)。
        public var isNeutral: Bool { temperature == 0 && tint == 0 }
    }

    /// 平均を取るときに除く画素: 一番明るい成分がこれ以上(白飛び)/ これ以下(黒つぶれ・背景の黒)。sRGB 符号化値の値。
    static let darkLimit = 0.02, brightLimit = 0.97

    // MARK: 実測表(CITemperatureAndTint の効き)

    /// 灰色にかけたときの log2(赤/青)の変化(色温度 −1 … +1)。初期値用の概算(実測は線形の作業色空間。描画は sRGB の作業色空間なので値が少し違い、ニュートン法で詰める)。
    static let temperatureTable: [(param: Double, effect: Double)] = [(-1, -1.49), (-0.5, -0.53), (0, 0), (0.5, 0.32), (1, 0.55)]
    /// ティント 1 あたりの log2(緑/(赤と青の平均))の変化(ほぼ直線: +1 で −0.83、−1 で +0.98)。
    static let tintSlope = -0.9

    /// 表を線形に補間して、効き `effect` を出す引数を返す(表の外は端)。
    static func invert(_ table: [(param: Double, effect: Double)], effect: Double) -> Double {
        guard let first = table.first, let last = table.last else { return 0 }
        if effect <= first.effect { return first.param }
        if effect >= last.effect { return last.param }
        for i in 1..<table.count where effect <= table[i].effect {
            let a = table[i - 1], b = table[i]
            let k = (effect - a.effect) / (b.effect - a.effect)
            return a.param + (b.param - a.param) * k
        }
        return last.param
    }

    // MARK: 決める

    /// sRGB 符号化値の平均色から、直す値を決める。どれかが 0 以下・有限でないときは nil。小数 2 桁に丸める。
    /// すでにほぼ灰色(偏りが 0.02 段未満)の軸は 0 にする。
    /// 実測表で初期値を作り、実際の `CITemperatureAndTint`(描画と同じフィルタ)で平均色を直した結果を見ながら、
    /// ニュートン法で赤/青の比と緑の偏りが 0 になる値を探す(フィルタは線形なので、平均色に当てた結果は画像に当てた平均と同じ)。
    /// 範囲(−1〜1)で直せないほど強いかぶりは、限界の値で止まる。
    public static func estimate(r: Double, g: Double, b: Double) -> Result? {
        guard r.isFinite, g.isFinite, b.isFinite, r > 1e-6, g > 1e-6, b > 1e-6 else { return nil }
        let rb0 = log2(r / b), gr0 = log2(g / ((r + b) / 2))
        let dead = 0.02
        if abs(rb0) < dead && abs(gr0) < dead { return Result(temperature: 0, tint: 0) }
        var x = initialGuess(r: r, g: g, b: b)
        func residual(_ x: (Double, Double)) -> (Double, Double)? {
            guard let o = applyFilter(r: r, g: g, b: b, temperature: x.0, tint: x.1), o.r > 1e-9, o.g > 1e-9, o.b > 1e-9 else { return nil }
            return (log2(o.r / o.b), log2(o.g / ((o.r + o.b) / 2)))
        }
        var best = x
        var bestErr = Double.infinity
        if let f = residual(x) { bestErr = max(abs(f.0), abs(f.1)) }
        let h = 0.03
        for _ in 0..<12 {
            guard let f = residual(x), bestErr > 0.004 else { break }
            guard let fa = residual((min(x.0 + h, 1) == x.0 ? x.0 - h : x.0 + h, x.1)),
                  let fb = residual((x.0, min(x.1 + h, 1) == x.1 ? x.1 - h : x.1 + h)) else { break }
            let dt = (min(x.0 + h, 1) == x.0 ? -h : h), dti = (min(x.1 + h, 1) == x.1 ? -h : h)
            let j00 = (fa.0 - f.0) / dt, j10 = (fa.1 - f.1) / dt
            let j01 = (fb.0 - f.0) / dti, j11 = (fb.1 - f.1) / dti
            let det = j00 * j11 - j01 * j10
            guard abs(det) > 1e-6 else { break }
            let st = -( j11 * f.0 - j01 * f.1) / det
            let sti = -(-j10 * f.0 + j00 * f.1) / det
            x = (min(max(x.0 + st, -1), 1), min(max(x.1 + sti, -1), 1))
            if let f2 = residual(x) {
                let e = max(abs(f2.0), abs(f2.1))
                if e < bestErr { bestErr = e; best = x }
            }
        }
        func round2(_ v: Double) -> Double { let y = (min(max(v, -1), 1) * 100).rounded() / 100; return y == 0 ? 0 : y }
        return Result(temperature: round2(best.0), tint: round2(best.1))
    }

    /// 実測表からの初期値(色温度は赤/青の比を表で逆に引く。ティントは直線)。
    static func initialGuess(r: Double, g: Double, b: Double) -> (Double, Double) {
        let rb = log2(r / b), green = log2(g / ((r + b) / 2))
        return (invert(temperatureTable, effect: -rb), min(max(-green / tintSlope, -1), 1))
    }

    /// sRGB の符号化値(0〜1)の 1 色に、描画と同じ `CITemperatureAndTint` と同じ作業色空間(Renderer の `ciContext`)でかけた結果。描けなければ nil。
    static func applyFilter(r: Double, g: Double, b: Double, temperature: Double, tint: Double) -> (r: Double, g: Double, b: Double)? {
        guard let lin = CGColorSpace(name: CGColorSpace.sRGB), let c = CIColor(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: 1, colorSpace: lin) else { return nil }
        let img = CIImage(color: c).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
            .applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500 + 2500 * temperature, y: 100 * tint),
                "inputTargetNeutral": CIVector(x: 6500, y: 0)])
        var px = [Float](repeating: 0, count: 4)
        ciContext.render(img, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: lin)
        return (Double(px[0]), Double(px[1]), Double(px[2]))
    }

    // MARK: 測る

    /// 画像の平均色(sRGB 符号化値)。白飛び・黒つぶれの画素は除く(残りが全体の 1% 未満なら全画素)。読めなければ nil。
    public static func averageColor(of image: CGImage) -> (r: Double, g: Double, b: Double)? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        return averageColor(rgba: buf, count: w * h)
    }

    /// RGBA8(sRGB の符号化値、アルファは無視)から。`count` は画素数。
    public static func averageColor(rgba: [UInt8], count: Int) -> (r: Double, g: Double, b: Double)? {
        guard count > 0, rgba.count >= count * 4 else { return nil }
        let lut = (0..<256).map { Double($0) / 255 }
        var sums = (r: 0.0, g: 0.0, b: 0.0), n = 0
        var all = (r: 0.0, g: 0.0, b: 0.0)
        for p in 0..<count {
            let r = lut[Int(rgba[p * 4])], g = lut[Int(rgba[p * 4 + 1])], b = lut[Int(rgba[p * 4 + 2])]
            all.r += r; all.g += g; all.b += b
            let hi = max(r, g, b)
            if hi >= darkLimit && hi <= brightLimit { sums.r += r; sums.g += g; sums.b += b; n += 1 }
        }
        if n * 100 >= count { return (sums.r / Double(n), sums.g / Double(n), sums.b / Double(n)) }
        return (all.r / Double(count), all.g / Double(count), all.b / Double(count))
    }

    /// 画像から直接決める。
    public static func estimate(from image: CGImage) -> Result? {
        guard let m = averageColor(of: image) else { return nil }
        return estimate(r: m.r, g: m.g, b: m.b)
    }

    // MARK: 測るためのプロジェクト

    /// 測る用の写し: そのクリップだけを置き、エフェクト・トランジション・不透明度・マスクを外し、小さく描く。元は変えない。
    /// 画像・動画のクリップだけ(それ以外は nil)。
    public static func measurementProject(for clip: Clip, in project: Project, width: Int = 192) -> Project? {
        guard clip.type == .image || clip.type == .video else { return nil }
        var c = clip
        c.effects = []
        c.keyframes = c.keyframes.filter { EffectKey.parse($0.key) == nil && $0.key != "opacity" }
        c.opacity = nil; c.transitionIn = nil; c.transitionOut = nil; c.mask = nil; c.blur = nil; c.stabilize = nil
        var p = project
        let aspect = Double(max(1, project.height)) / Double(max(1, project.width))
        p.width = width
        p.height = max(2, Int((Double(width) * aspect).rounded()))
        var t = Track(); t.clips = [c]
        p.tracks = [t]
        p.markers = []; p.rangeIn = nil; p.rangeOut = nil
        return p
    }

    // MARK: クリップに当てる

    /// クリップの `whiteBalance` エフェクトに値を入れる(最初の 1 つを使い、無ければ末尾に足す。無効なら有効に戻し、
    /// 色温度・ティントのキーフレームは消す)。ほぼ灰色(`isNeutral`)でエフェクトも無いときは何もしない。変化があれば true。
    @discardableResult
    public static func apply(_ result: Result, to c: inout Clip) -> Bool {
        guard EffectEditing.supports(c.type) else { return false }
        let before = c
        if let i = c.effects.firstIndex(where: { $0.known == .whiteBalance }) {
            c.effects[i].enabled = true
            c.effects[i].params["temperature"] = result.temperature
            c.effects[i].params["tint"] = result.tint
            c.keyframes[EffectKey.make(i, "temperature")] = nil
            c.keyframes[EffectKey.make(i, "tint")] = nil
        } else {
            guard !result.isNeutral else { return false }
            var e = Effect(.whiteBalance)
            e.params["temperature"] = result.temperature
            e.params["tint"] = result.tint
            c.effects.append(e)
        }
        return c != before
    }
}
