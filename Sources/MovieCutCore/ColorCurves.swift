import Foundation

/// カーブ(トーンカーブ・色相カーブ)の計算。結果は 3D カラールックアップ表(33³)にして CIColorCube に渡す。
///
/// - トーンカーブ: 入力 0〜1 → 出力 0〜1 の 1 次元カーブ。固定 x の 5 点を Catmull-Rom スプラインでなめらかにつなぐ。
///   マスター・赤・緑・青の 4 本。**適用順はチャンネル別カーブ → マスターカーブ**(各チャンネルに自分のカーブを当ててからマスターを当てる)。
/// - 色相カーブ: 入力の色相に対する 色相シフト・彩度倍率・輝度オフセット の 3 本。h = 0, 0.2, 0.4, 0.6, 0.8 の 5 点を循環補間する(継ぎ目で途切れない)。
/// 全部が恒等なら何もしない(入力をそのまま返す)。
public enum ColorCurves {
    /// 1 本のトーンカーブ(`anchorX` の 5 点に対する y 値)。
    public struct Curve: Equatable, Sendable {
        public var y: [Double]
        public init(y: [Double]) { self.y = y }
        /// 恒等(y == anchorX)。
        public static let identity = Curve(y: ColorCurves.anchorX)
    }

    /// 4 本のトーンカーブ(マスター・赤・緑・青)。適用順はチャンネル別 → マスター。
    public struct ToneCurves: Equatable, Sendable {
        public var master: Curve
        public var red: Curve
        public var green: Curve
        public var blue: Curve
        public init(master: Curve = .identity, red: Curve = .identity, green: Curve = .identity, blue: Curve = .identity) {
            self.master = master; self.red = red; self.green = green; self.blue = blue
        }
        public static let identity = ToneCurves()
    }

    /// 色相カーブ 3 本(各 5 点。点の色相は `hueAnchorX`)。
    public struct HueCurves: Equatable, Sendable {
        /// 色相シフト(度、−180〜180、恒等 0)。
        public var hueShiftY: [Double]
        /// 彩度倍率(0〜2、恒等 1)。
        public var satScaleY: [Double]
        /// 輝度オフセット(−0.5〜0.5、恒等 0)。
        public var lumOffsetY: [Double]
        public init(hueShiftY: [Double] = Array(repeating: 0, count: 5),
                    satScaleY: [Double] = Array(repeating: 1, count: 5),
                    lumOffsetY: [Double] = Array(repeating: 0, count: 5)) {
            self.hueShiftY = hueShiftY; self.satScaleY = satScaleY; self.lumOffsetY = lumOffsetY
        }
        public static let identity = HueCurves()

        /// 入力色相 h(0..<1)での色相シフト(度)。
        public func hueShift(at h: Double) -> Double {
            min(max(ColorCurves.evalCyclic(hueShiftY, h), -180), 180)
        }
        /// 入力色相 h(0..<1)での彩度倍率。
        public func satScale(at h: Double) -> Double {
            min(max(ColorCurves.evalCyclic(satScaleY, h), 0), 2)
        }
        /// 入力色相 h(0..<1)での輝度オフセット。
        public func lumOffset(at h: Double) -> Double {
            min(max(ColorCurves.evalCyclic(lumOffsetY, h), -0.5), 0.5)
        }
    }

    /// トーンカーブの制御点の x(固定)。
    public static let anchorX: [Double] = [0, 0.25, 0.5, 0.75, 1]
    /// 色相カーブの制御点の色相(h = 1 は h = 0 と同一)。
    public static let hueAnchorX: [Double] = [0, 0.2, 0.4, 0.6, 0.8]
    /// 3D 表の 1 辺の画素数(33³ = 35937 点)。
    public static let cubeDimension = 33

    // MARK: 補間

    /// Hermite 基底で 1 区間を補間する(t は 0...1、m0・m1 は区間幅 1 に換算した接線)。
    static func hermite(_ p0: Double, _ p1: Double, _ m0: Double, _ m1: Double, _ t: Double) -> Double {
        let t2 = t * t, t3 = t2 * t
        return (2 * t3 - 3 * t2 + 1) * p0 + (t3 - 2 * t2 + t) * m0 + (-2 * t3 + 3 * t2) * p1 + (t3 - t2) * m1
    }

    /// トーンカーブの評価(Catmull-Rom)。入力・出力とも 0...1 にクランプする。
    /// 端点の接線は隣接点から外挿する(p₋₁ = 2p₀ − p₁)。恒等曲線なら eval(x) == x、各制御点では y[i] を通る。
    public static func eval(_ curve: Curve, _ x: Double) -> Double {
        let y = curve.y
        guard y.count == 5 else { return ColorHSL.clamp01(x) }
        let x = ColorHSL.clamp01(x)
        let pos = x * 4
        let i = min(Int(pos), 3)
        let t = pos - Double(i)
        // 接線(端点は隣接点からの外挿 = 隣との差)
        func tangent(_ k: Int) -> Double {
            if k == 0 { return y[1] - y[0] }
            if k == 4 { return y[4] - y[3] }
            return (y[k + 1] - y[k - 1]) / 2
        }
        let v = hermite(y[i], y[i + 1], tangent(i), tangent(i + 1), t)
        return ColorHSL.clamp01(v)
    }

    /// 色相カーブ用の循環 Catmull-Rom 評価(5 点、h は循環で正規化)。クランプは呼び出し側で行う。
    static func evalCyclic(_ y: [Double], _ h: Double) -> Double {
        guard y.count == 5 else { return 0 }
        let h0 = h.isFinite ? h : 0
        let hh = h0 - floor(h0)
        let pos = hh * 5
        let i = min(Int(pos), 4)
        let t = pos - Double(i)
        func tangent(_ k: Int) -> Double { (y[(k + 1) % 5] - y[(k + 4) % 5]) / 2 }
        return hermite(y[i], y[(i + 1) % 5], tangent(i), tangent((i + 1) % 5), t)
    }

    // MARK: 恒等判定・合成

    /// 2 つの配列が許容誤差内で等しいか。
    private static func near(_ a: [Double], _ b: [Double], _ eps: Double) -> Bool {
        guard a.count == b.count else { return false }
        for (p, q) in zip(a, b) where !(abs(p - q) <= eps) { return false }
        return true
    }

    static func toneIsIdentity(_ tone: ToneCurves, eps: Double) -> Bool {
        [tone.master, tone.red, tone.green, tone.blue].allSatisfy { near($0.y, anchorX, eps) }
    }

    static func hueIsIdentity(_ hue: HueCurves, eps: Double) -> Bool {
        near(hue.hueShiftY, Array(repeating: 0, count: 5), eps)
            && near(hue.satScaleY, Array(repeating: 1, count: 5), eps)
            && near(hue.lumOffsetY, Array(repeating: 0, count: 5), eps)
    }

    /// 全部が恒等(何もしない)か。eps は点ごとの許容誤差。
    public static func isIdentity(tone: ToneCurves, hue: HueCurves, eps: Double = 1e-9) -> Bool {
        toneIsIdentity(tone, eps: eps) && hueIsIdentity(hue, eps: eps)
    }

    /// 1 点の変換(0〜1 の RGB → 0〜1 の RGB)。トーンカーブ → HSL → 色相カーブ → RGB の順。
    /// 全部が恒等なら入力をそのまま返す(画素不変を厳密に保証)。
    public static func mapRGB(r: Double, g: Double, b: Double, tone: ToneCurves, hue: HueCurves) -> (r: Double, g: Double, b: Double) {
        if isIdentity(tone: tone, hue: hue) { return (r, g, b) }
        return map(r: r, g: g, b: b, tone: tone, hue: hue,
                   toneActive: !toneIsIdentity(tone, eps: 1e-9), hueActive: !hueIsIdentity(hue, eps: 1e-9))
    }

    static func map(r: Double, g: Double, b: Double, tone: ToneCurves, hue: HueCurves,
                    toneActive: Bool, hueActive: Bool) -> (r: Double, g: Double, b: Double) {
        var rgb = (r: r, g: g, b: b)
        if toneActive {
            rgb = (eval(tone.master, eval(tone.red, r)),
                   eval(tone.master, eval(tone.green, g)),
                   eval(tone.master, eval(tone.blue, b)))
        }
        if hueActive {
            let c = ColorHSL.hsl(r: rgb.r, g: rgb.g, b: rgb.b)
            let h = c.h + hue.hueShift(at: c.h) / 360
            let s = min(max(c.s * hue.satScale(at: c.h), 0), 1)
            let l = min(max(c.l + hue.lumOffset(at: c.h), 0), 1)
            rgb = ColorHSL.rgb(h: h, s: s, l: l)
        }
        return rgb
    }

    /// CIColorCube 用のデータ(Float の RGBA × cubeDimension³、赤が一番速く動く並び)。
    public static func cubeData(tone: ToneCurves, hue: HueCurves) -> Data {
        let n = cubeDimension
        let toneActive = !toneIsIdentity(tone, eps: 1e-9)
        let hueActive = !hueIsIdentity(hue, eps: 1e-9)
        var floats = [Float]()
        floats.reserveCapacity(n * n * n * 4)
        let step = 1 / Double(n - 1)
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let m = map(r: Double(r) * step, g: Double(g) * step, b: Double(b) * step,
                                tone: tone, hue: hue, toneActive: toneActive, hueActive: hueActive)
                    floats.append(Float(m.r)); floats.append(Float(m.g)); floats.append(Float(m.b)); floats.append(1)
                }
            }
        }
        return floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    // MARK: 引数からの復元

    /// 引数値(キー → 値)からトーンカーブを復元する。キーは `master0`〜`master4`・`red0`…・`green0`…・`blue0`…(0 始まり)。
    /// `values` は存在しないキーでも既定(恒等)を返す関数を渡すこと。
    public static func toneCurves(from values: (String) -> Double) -> ToneCurves {
        func curve(_ prefix: String) -> Curve { Curve(y: (0..<5).map { values("\(prefix)\($0)") }) }
        return ToneCurves(master: curve("master"), red: curve("red"), green: curve("green"), blue: curve("blue"))
    }

    /// 引数値からの色相カーブ復元。キーは `hueHue0`〜`hueHue4`(色相シフト)・`hueSat0`…(彩度倍率)・`hueLum0`…(輝度オフセット)。
    public static func hueCurves(from values: (String) -> Double) -> HueCurves {
        HueCurves(hueShiftY: (0..<5).map { values("hueHue\($0)") },
                  satScaleY: (0..<5).map { values("hueSat\($0)") },
                  lumOffsetY: (0..<5).map { values("hueLum\($0)") })
    }
}
