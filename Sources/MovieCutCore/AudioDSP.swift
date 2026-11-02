import Foundation

// 音声エフェクトの信号処理(純粋な Swift。Audio Unit は使わないので、同じ入力なら必ず同じ出力になる)。
// すべて 48 kHz ステレオ Float32(左右別)のブロックをその場で書き換える。

// MARK: - 2 次フィルタ(RBJ Audio EQ Cookbook)

struct Biquad: Equatable {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0

    /// 係数(a0 で割った形)から。
    init(b0: Double, b1: Double, b2: Double, a0: Double, a1: Double, a2: Double) {
        self.b0 = b0 / a0; self.b1 = b1 / a0; self.b2 = b2 / a0; self.a1 = a1 / a0; self.a2 = a2 / a0
    }
    init() {}

    /// 低域シェルフ(スロープ S = 1)。f0 より下を gainDb だけ持ち上げ/下げ。
    static func lowShelf(f0: Double, gainDb: Double, sr: Double) -> Biquad {
        let A = pow(10, gainDb / 40), w = 2 * Double.pi * f0 / sr, cw = cos(w), sw = sin(w)
        let alpha = sw / 2 * (2.0).squareRoot()
        let t = 2 * A.squareRoot() * alpha
        return Biquad(b0: A * ((A + 1) - (A - 1) * cw + t), b1: 2 * A * ((A - 1) - (A + 1) * cw), b2: A * ((A + 1) - (A - 1) * cw - t),
                      a0: (A + 1) + (A - 1) * cw + t, a1: -2 * ((A - 1) + (A + 1) * cw), a2: (A + 1) + (A - 1) * cw - t)
    }

    /// 高域シェルフ(スロープ S = 1)。
    static func highShelf(f0: Double, gainDb: Double, sr: Double) -> Biquad {
        let A = pow(10, gainDb / 40), w = 2 * Double.pi * f0 / sr, cw = cos(w), sw = sin(w)
        let alpha = sw / 2 * (2.0).squareRoot()
        let t = 2 * A.squareRoot() * alpha
        return Biquad(b0: A * ((A + 1) + (A - 1) * cw + t), b1: -2 * A * ((A - 1) + (A + 1) * cw), b2: A * ((A + 1) + (A - 1) * cw - t),
                      a0: (A + 1) - (A - 1) * cw + t, a1: 2 * ((A - 1) - (A + 1) * cw), a2: (A + 1) - (A - 1) * cw - t)
    }

    /// ピーキング。
    static func peaking(f0: Double, gainDb: Double, q: Double, sr: Double) -> Biquad {
        let A = pow(10, gainDb / 40), w = 2 * Double.pi * f0 / sr, cw = cos(w), alpha = sin(w) / (2 * q)
        return Biquad(b0: 1 + alpha * A, b1: -2 * cw, b2: 1 - alpha * A, a0: 1 + alpha / A, a1: -2 * cw, a2: 1 - alpha / A)
    }

    /// ハイパス(RBJ Cookbook、Q 指定)。
    static func highPass(f0: Double, q: Double, sr: Double) -> Biquad {
        let w = 2 * Double.pi * f0 / sr, cw = cos(w), alpha = sin(w) / (2 * q)
        return Biquad(b0: (1 + cw) / 2, b1: -(1 + cw), b2: (1 + cw) / 2, a0: 1 + alpha, a1: -2 * cw, a2: 1 - alpha)
    }

    /// 周波数 f での振幅(倍率)。試験・確認用。
    func magnitude(at f: Double, sr: Double) -> Double {
        let w = 2 * Double.pi * f / sr
        let c1 = cos(w), s1 = sin(w), c2 = cos(2 * w), s2 = sin(2 * w)
        let nr = b0 + b1 * c1 + b2 * c2, ni = -(b1 * s1 + b2 * s2)
        let dr = 1 + a1 * c1 + a2 * c2, di = -(a1 * s1 + a2 * s2)
        return ((nr * nr + ni * ni) / (dr * dr + di * di)).squareRoot()
    }
}

/// 1 チャンネルぶんの状態(転置直接形 II)。
struct BiquadState {
    var z1 = 0.0, z2 = 0.0
    @inline(__always)
    mutating func run(_ c: Biquad, _ x: Double) -> Double {
        let y = c.b0 * x + z1
        z1 = c.b1 * x - c.a1 * y + z2
        z2 = c.b2 * x - c.a2 * y
        return y
    }
}

// MARK: - イコライザー

final class EQProcessor {
    private var bands: [Biquad] = []
    private var stateL: [BiquadState]
    private var stateR: [BiquadState]

    init(_ eq: AudioFx.EQ, sr: Double) {
        if eq.lowDb != 0 { bands.append(.lowShelf(f0: 100, gainDb: eq.lowDb, sr: sr)) }
        if eq.midDb != 0 { bands.append(.peaking(f0: 1000, gainDb: eq.midDb, q: 1, sr: sr)) }
        if eq.highDb != 0 { bands.append(.highShelf(f0: 8000, gainDb: eq.highDb, sr: sr)) }
        stateL = Array(repeating: BiquadState(), count: bands.count)
        stateR = Array(repeating: BiquadState(), count: bands.count)
    }

    /// 全バンドをかけた周波数応答(振幅の倍率)。
    static func magnitude(_ eq: AudioFx.EQ, at f: Double, sr: Double) -> Double {
        var m = 1.0
        if eq.lowDb != 0 { m *= Biquad.lowShelf(f0: 100, gainDb: eq.lowDb, sr: sr).magnitude(at: f, sr: sr) }
        if eq.midDb != 0 { m *= Biquad.peaking(f0: 1000, gainDb: eq.midDb, q: 1, sr: sr).magnitude(at: f, sr: sr) }
        if eq.highDb != 0 { m *= Biquad.highShelf(f0: 8000, gainDb: eq.highDb, sr: sr).magnitude(at: f, sr: sr) }
        return m
    }

    func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int) {
        guard !bands.isEmpty else { return }
        for b in 0..<bands.count {
            let c = bands[b]
            for i in 0..<n {
                l[i] = Float(stateL[b].run(c, Double(l[i])))
                r[i] = Float(stateR[b].run(c, Double(r[i])))
            }
        }
    }
}

// MARK: - コンプレッサー

/// ステレオリンクのフィードフォワード型。ピーク検出(アタック / リリースつきの包絡)→ 閾値を超えた分を 1/ratio に圧縮 → メイクアップ。
final class CompressorProcessor {
    private let thr: Double, slope: Double, makeup: Double
    private let atk: Double, rel: Double
    private let thrLin: Double
    private(set) var env = 0.0

    init(_ c: AudioFx.Compressor, sr: Double) {
        thr = c.thresholdDb
        slope = 1 - 1 / c.ratioValue
        makeup = c.makeupDb
        atk = 1 - exp(-1 / (c.attackMs * 0.001 * sr))
        rel = 1 - exp(-1 / (c.releaseMs * 0.001 * sr))
        thrLin = pow(10, c.thresholdDb / 20)
    }

    /// 包絡 `e`(線形)での、かける倍率(dB)。
    @inline(__always)
    func gainDb(forEnvelope e: Double) -> Double {
        if e <= thrLin { return makeup }
        let over = 20 * log10(e) - thr
        return makeup - over * slope
    }

    func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int) {
        let flatGain = Float(pow(10, makeup / 20))
        for i in 0..<n {
            let x = Double(max(abs(l[i]), abs(r[i])))
            env += (x - env) * (x > env ? atk : rel)
            if env <= thrLin {
                if makeup != 0 { l[i] *= flatGain; r[i] *= flatGain }
            } else {
                let g = Float(pow(10, gainDb(forEnvelope: env) / 20))
                l[i] *= g; r[i] *= g
            }
        }
    }
}

// MARK: - リバーブ(Freeverb 方式)

/// 並列 8 本のコムフィルタ + 直列 4 本のオールパス(左右でコムの長さを少しずらす)。
/// `mix` が 0 のときは何もしない(原音そのまま)。クリップの終わりより後ろの余韻は出さない。
final class ReverbProcessor {
    private struct Comb {
        var buf: [Float]; var idx = 0; var store: Float = 0
        init(_ n: Int) { buf = [Float](repeating: 0, count: max(1, n)) }
    }
    private struct AllPass {
        var buf: [Float]; var idx = 0
        init(_ n: Int) { buf = [Float](repeating: 0, count: max(1, n)) }
    }

    private static let combTunings = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617]
    private static let allPassTunings = [556, 441, 341, 225]
    private static let stereoSpread = 23

    /// 部屋の大きさごとの (フィードバック, 高域の減衰, 長さの倍率)
    static func params(for size: AudioFx.ReverbSize) -> (feedback: Float, damp: Float, scale: Double) {
        switch size {
        case .small: return (0.78, 0.50, 0.6)
        case .medium: return (0.84, 0.45, 1.0)
        case .large: return (0.89, 0.40, 1.4)
        case .hall: return (0.93, 0.30, 1.8)
        }
    }

    private let mix: Float
    private let feedback: Float, damp1: Float, damp2: Float
    private var combL: [Comb], combR: [Comb], apL: [AllPass], apR: [AllPass]

    init(_ r: AudioFx.Reverb, sr: Double) {
        mix = Float(r.mix)
        let p = Self.params(for: r.sizeOrDefault)
        feedback = p.feedback; damp1 = p.damp; damp2 = 1 - p.damp
        let k = sr / 44100 * p.scale
        func len(_ n: Int) -> Int { max(8, Int((Double(n) * k).rounded())) }
        combL = Self.combTunings.map { Comb(len($0)) }
        combR = Self.combTunings.map { Comb(len($0 + Self.stereoSpread)) }
        apL = Self.allPassTunings.map { AllPass(len($0)) }
        apR = Self.allPassTunings.map { AllPass(len($0 + Self.stereoSpread)) }
    }

    func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int) {
        guard mix > 0 else { return }
        let dryGain = 1 - mix, wetGain = mix * 3
        for i in 0..<n {
            let input = (l[i] + r[i]) * 0.015
            var oL: Float = 0, oR: Float = 0
            for c in 0..<combL.count {
                do { // 左
                    let out = combL[c].buf[combL[c].idx]
                    combL[c].store = out * damp2 + combL[c].store * damp1
                    combL[c].buf[combL[c].idx] = input + combL[c].store * feedback
                    combL[c].idx += 1; if combL[c].idx >= combL[c].buf.count { combL[c].idx = 0 }
                    oL += out
                }
                do { // 右
                    let out = combR[c].buf[combR[c].idx]
                    combR[c].store = out * damp2 + combR[c].store * damp1
                    combR[c].buf[combR[c].idx] = input + combR[c].store * feedback
                    combR[c].idx += 1; if combR[c].idx >= combR[c].buf.count { combR[c].idx = 0 }
                    oR += out
                }
            }
            for a in 0..<apL.count {
                let bl = apL[a].buf[apL[a].idx]
                apL[a].buf[apL[a].idx] = oL + bl * 0.5
                apL[a].idx += 1; if apL[a].idx >= apL[a].buf.count { apL[a].idx = 0 }
                oL = bl - oL
                let br = apR[a].buf[apR[a].idx]
                apR[a].buf[apR[a].idx] = oR + br * 0.5
                apR[a].idx += 1; if apR[a].idx >= apR[a].buf.count { apR[a].idx = 0 }
                oR = br - oR
            }
            l[i] = l[i] * dryGain + oL * wetGain
            r[i] = r[i] * dryGain + oR * wetGain
        }
    }
}

// MARK: - ノイズ除去(簡易: 80 Hz ハイパス + 静かな所を下げるエクスパンダー)

/// 静かな所(RMS 10 ms の包絡が −30 dBFS より下)を下げる。下げ方は強さ s(0〜1)で決まる:
/// しきい値より 1 dB 下がるごとに (1 + 2s) dB 下げ、下げ幅は最大 30s dB。ステレオは左右連動。
/// 開くのは 80 ms・閉じるのは 5 ms で滑らかにする(ぶつぶつ切れないように)。信号が大きいところは素通し。
/// 乱数を使わないので、同じ入力なら必ず同じ出力になる。
final class DenoiseProcessor {
    static let thresholdDb = -30.0
    private let slope: Double
    private let maxReductionDb: Double
    private let hp: Biquad
    private var stateL = BiquadState(), stateR = BiquadState()
    private var ms = 0.0
    private var gain = 1.0
    private let msCoef: Double, closeCoef: Double, openCoef: Double

    init(strength: Double, sr: Double) {
        let s = AudioFx.clampDenoise(strength)
        slope = 1 + 2 * s
        maxReductionDb = 30 * s
        hp = Biquad.highPass(f0: 80, q: 0.707, sr: sr)
        msCoef = 1 - exp(-1 / (0.010 * sr))
        closeCoef = 1 - exp(-1 / (0.005 * sr))
        openCoef = 1 - exp(-1 / (0.080 * sr))
    }

    func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int) {
        for i in 0..<n {
            let x = stateL.run(hp, Double(l[i])), y = stateR.run(hp, Double(r[i]))
            ms += ((x * x + y * y) * 0.5 - ms) * msCoef
            let levelDb = 10 * log10(max(ms, 1e-12))
            var targetDb = 0.0
            if levelDb < Self.thresholdDb { targetDb = max(-maxReductionDb, (levelDb - Self.thresholdDb) * slope) }
            let target = pow(10, targetDb / 20)
            gain += (target - gain) * (target < gain ? closeCoef : openCoef)
            l[i] = Float(x * gain); r[i] = Float(y * gain)
        }
    }
}

// MARK: - ノイズゲート(しきい値より小さい音を閉じる)

/// 左右連動のノイズゲート。包絡は短い窓(5 ms の二乗平均)で測り、しきい値を超えたら開く。
/// 閉じるのはしきい値より 3 dB 下がってから(ヒステリシス)で、開いたあと 100 ms は閉じない(ホールド)。
/// 開く速さ 2 ms・閉じる速さ 60 ms の一次の滑らかさで、プチッという音を避ける。閉じたときの下げ幅は −60 dB。
/// 最初は閉じた状態から始める。乱数を使わないので、同じ入力なら必ず同じ出力になる。
final class GateProcessor {
    static let floorGain = 0.001   // −60 dB
    private let openThreshold: Double, closeThreshold: Double
    private let holdSamples: Int
    private var ms = 0.0
    private var gain = GateProcessor.floorGain
    private var isOpen = false
    private var holdLeft = 0
    private let msCoef: Double, openCoef: Double, closeCoef: Double

    init(thresholdDb: Double, sr: Double) {
        // 二乗平均(電力)で比べるので 10·log10 の逆変換
        openThreshold = pow(10, thresholdDb / 10)
        closeThreshold = pow(10, (thresholdDb - 3) / 10)
        holdSamples = Int(0.100 * sr)
        msCoef = 1 - exp(-1 / (0.005 * sr))
        openCoef = 1 - exp(-1 / (0.002 * sr))
        closeCoef = 1 - exp(-1 / (0.060 * sr))
    }

    func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int) {
        for i in 0..<n {
            let x = Double(l[i]), y = Double(r[i])
            ms += ((x * x + y * y) * 0.5 - ms) * msCoef
            if isOpen {
                if ms >= closeThreshold { holdLeft = holdSamples }
                else if holdLeft > 0 { holdLeft -= 1 }
                else { isOpen = false }
            } else if ms >= openThreshold {
                isOpen = true; holdLeft = holdSamples
            }
            let target = isOpen ? 1.0 : Self.floorGain
            gain += (target - gain) * (target > gain ? openCoef : closeCoef)
            l[i] = Float(x * gain); r[i] = Float(y * gain)
        }
    }
}

// MARK: - リミッター(天井を超えないように抑える)

/// 先読み 2 ms のピークリミッター。左右連動。
/// 各サンプルの必要な倍率 `天井 / ピーク`(1 を超えない)について、先読み窓の最小値を取り、直前の窓幅ぶんで平均する。
/// こうすると、ピークが来る時点の倍率は必ずそのピークに必要な倍率以下になる(遅延なしで天井を守る)。
/// 戻りは 100 ms の一次の滑らかさ。塊の終わり・素材の頭では先読みが足りないので、最後に天井で切って保証する(安全策)。
final class LimiterProcessor {
    private let ceiling: Float
    private let look: Int
    private let relCoef: Double
    private var prevM: [Float]      // 前の塊の最後の (look-1) 個の最小値
    private var rel = 1.0

    init(ceilingDb: Double, sr: Double) {
        ceiling = Float(pow(10, ceilingDb / 20))
        look = max(2, Int(0.002 * sr))
        relCoef = 1 - exp(-1 / (0.100 * sr))
        prevM = [Float](repeating: 1, count: look - 1)
    }

    func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int) {
        guard n > 0 else { return }
        let c = ceiling
        var req = [Float](repeating: 1, count: n)
        for i in 0..<n {
            let p = max(abs(l[i]), abs(r[i]))
            req[i] = p > c ? c / p : 1
        }
        // m[k] = req[k ..< k+look] の最小(窓は塊の終わりで切る)。後ろから走査する単調な両端キューで O(n)
        var m = [Float](repeating: 1, count: n)
        var dq = [Int](repeating: 0, count: n)
        var head = 0, tail = 0
        var k = n - 1
        while k >= 0 {
            while tail > head && req[dq[tail - 1]] >= req[k] { tail -= 1 }
            dq[tail] = k; tail += 1
            while dq[head] >= k + look { head += 1 }
            m[k] = req[dq[head]]
            k -= 1
        }
        // 前の塊の m を前に足した列 ext を、各位置で直前の look 個で平均する
        let pad = look - 1
        var sum = 0.0
        for j in 0..<pad { sum += Double(prevM[j]) }
        for i in 0..<n {
            sum += Double(m[i])
            let gd = sum / Double(look)
            rel = gd < rel ? gd : rel + (1 - rel) * relCoef
            let out = Float(min(gd, rel))
            l[i] = max(min(l[i] * out, c), -c)
            r[i] = max(min(r[i] * out, c), -c)
            sum -= Double(i < pad ? prevM[i] : m[i - pad])
        }
        if n >= pad { prevM = Array(m[(n - pad)...]) } else { prevM = Array(prevM[n...]) + m }
    }
}

// MARK: - 処理の連なり(ノイズ除去 → ゲート → EQ → コンプレッサー → リバーブ → リミッター)

/// 1 つのクリップにかける ノイズ除去 → EQ → コンプレッサー → リバーブ。ブロックごとに `process` を呼ぶと、状態が続く。
final class AudioFxChain {
    private let denoise: DenoiseProcessor?
    private let gate: GateProcessor?
    private let limiter: LimiterProcessor?
    private let eq: EQProcessor?
    private let comp: CompressorProcessor?
    private let reverb: ReverbProcessor?

    init(_ fx: AudioFx, sr: Double) {
        denoise = fx.denoiseStrength > 0 ? DenoiseProcessor(strength: fx.denoiseStrength, sr: sr) : nil
        gate = fx.gateDb.map { GateProcessor(thresholdDb: $0, sr: sr) }
        limiter = fx.limiterDb.map { LimiterProcessor(ceilingDb: $0, sr: sr) }
        eq = fx.eq.flatMap { $0.isActive ? EQProcessor($0, sr: sr) : nil }
        comp = fx.compressor.flatMap { $0.isActive ? CompressorProcessor($0, sr: sr) : nil }
        reverb = fx.reverb.flatMap { $0.isActive ? ReverbProcessor($0, sr: sr) : nil }
    }

    func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int) {
        denoise?.process(l, r, n)
        gate?.process(l, r, n)
        eq?.process(l, r, n)
        comp?.process(l, r, n)
        reverb?.process(l, r, n)
        limiter?.process(l, r, n)
    }
}

// MARK: - ノーマライズ(測って倍率を決める)

/// ピークと、K 特性(ITU-R BS.1770 の 2 段フィルタ)をかけた二乗平均を測る。ゲートは使わない簡易なラウドネス。
final class LevelMeter {
    private(set) var peak: Float = 0
    private var sumSq = 0.0
    private(set) var frames = 0
    private var pre = (l: BiquadState(), r: BiquadState()), rlb = (l: BiquadState(), r: BiquadState())
    // 48 kHz 用の係数(BS.1770-4)
    static let preFilter = Biquad(b0: 1.53512485958697, b1: -2.69169618940638, b2: 1.19839281085285, a0: 1, a1: -1.69065929318241, a2: 0.73248077421585)
    static let rlbFilter = Biquad(b0: 1, b1: -2, b2: 1, a0: 1, a1: -1.99004745483398, a2: 0.99007225036621)

    func add(_ l: UnsafePointer<Float>, _ r: UnsafePointer<Float>, _ n: Int) {
        for i in 0..<n {
            peak = max(peak, abs(l[i]), abs(r[i]))
            let yl = rlb.l.run(Self.rlbFilter, pre.l.run(Self.preFilter, Double(l[i])))
            let yr = rlb.r.run(Self.rlbFilter, pre.r.run(Self.preFilter, Double(r[i])))
            sumSq += yl * yl + yr * yr
        }
        frames += n
    }

    var peakDb: Double { peak > 0 ? 20 * log10(Double(peak)) : -.infinity }

    /// 全体のラウドネス(LUFS 相当)。無音は −∞。
    var loudness: Double {
        guard frames > 0, sumSq > 0 else { return -.infinity }
        return -0.691 + 10 * log10(sumSq / Double(frames))
    }
}

enum AudioNormalizer {
    /// 上げすぎない上限(dB)。ほぼ無音の素材を持ち上げて雑音だらけにしない。
    static let maxBoostDb = 48.0

    /// 測った結果から、かける倍率(線形)。無音は 1。ラウドネスのときは、ピークが −0.1 dBFS を超えない範囲に収める。
    static func gain(_ n: AudioFx.Normalize, meter: LevelMeter) -> Float {
        guard meter.peak > 1e-6 else { return 1 }
        var gDb: Double
        switch n.modeOrDefault {
        case .peak:
            gDb = n.targetDb - meter.peakDb
        case .loudness:
            let l = meter.loudness
            guard l.isFinite else { return 1 }
            gDb = n.targetDb - l
            gDb = min(gDb, -0.1 - meter.peakDb)
        }
        gDb = min(gDb, maxBoostDb)
        return Float(pow(10, gDb / 20))
    }
}

// MARK: - パン(等パワー)

public enum AudioPan {
    /// 左右にかける倍率。中央(0)は左右とも 1(原音のまま)で、左右の二乗和は常に 2(等パワー)。
    /// 端いっぱいでは、鳴る側が +3 dB になる。
    public static func gains(_ pan: Double) -> (l: Float, r: Float) {
        let p = pan.isFinite ? min(max(pan, -1), 1) : 0
        let theta = (p + 1) * Double.pi / 4
        let s2 = 2.0.squareRoot()
        return (Float(s2 * cos(theta)), Float(s2 * sin(theta)))
    }
}

// MARK: - 音量の包絡(キーフレーム)

/// 音量のキーフレームを、サンプルごとの倍率にする。クリップの頭からのサンプル位置で評価するので、塊の境目でも途切れない。
/// 位置は前へ進む使い方が基本(区間の番号を覚えておく)で、戻っても正しく求める。
final class VolumeEnvelope {
    private let keys: [Keyframe]
    private let sr: Double
    private var seg = 0

    init?(_ raw: [Keyframe]?, sr: Double) {
        guard let raw, !raw.isEmpty else { return nil }
        keys = Animation.normalized(raw)
        guard !keys.isEmpty else { return nil }
        self.sr = sr
    }

    /// クリップの頭から `pos` 番目のサンプルでの倍率(0〜2)。
    func gain(at pos: Int) -> Float {
        let t = Double(pos) / sr
        guard keys.count > 1, let first = keys.first, let last = keys.last else { return Self.clamp(keys[0].v) }
        if t <= first.t { return Self.clamp(first.v) }
        if t >= last.t { return Self.clamp(last.v) }
        while seg > 0 && keys[seg].t > t { seg -= 1 }
        while seg + 1 < keys.count - 1 && keys[seg + 1].t <= t { seg += 1 }
        let a = keys[seg], b = keys[seg + 1]
        let span = b.t - a.t
        guard span > 0 else { return Self.clamp(b.v) }
        let k = a.ease.apply((t - a.t) / span)
        return Self.clamp(a.v + (b.v - a.v) * k)
    }

    private static func clamp(_ v: Double) -> Float { Float(min(max(v, 0), 2)) }
}
