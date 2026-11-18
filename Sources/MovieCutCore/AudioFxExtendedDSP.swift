import Foundation

// 拡張エフェクトの信号処理(純粋な Swift、既存の AudioDSP.swift と同じ流儀)。
// すべて 48 kHz 前提のステレオ Float32 ブロックをその場で書き換え、乱数を使わない(決定的)。
// エフェクトが無い/無効なときはプロセッサ自体を作らないので、従来の音声経路と完全一致する。

// MARK: - 2 次フィルタの追加分(RBJ Audio EQ Cookbook)

extension Biquad {
    /// ローパス(Q 指定)。
    static func lowPass(f0: Double, q: Double, sr: Double) -> Biquad {
        let w = 2 * Double.pi * f0 / sr, cw = cos(w), alpha = sin(w) / (2 * q)
        return Biquad(b0: (1 - cw) / 2, b1: 1 - cw, b2: (1 - cw) / 2, a0: 1 + alpha, a1: -2 * cw, a2: 1 - alpha)
    }

    /// バンドパス(ピーク利得 0 dB 型、Q 指定)。
    static func bandPass(f0: Double, q: Double, sr: Double) -> Biquad {
        let w = 2 * Double.pi * f0 / sr, cw = cos(w), alpha = sin(w) / (2 * q)
        return Biquad(b0: alpha, b1: 0, b2: -alpha, a0: 1 + alpha, a1: -2 * cw, a2: 1 - alpha)
    }

    /// ノッチ(指定周波数だけを落とす、Q 指定)。
    static func notch(f0: Double, q: Double, sr: Double) -> Biquad {
        let w = 2 * Double.pi * f0 / sr, cw = cos(w), alpha = sin(w) / (2 * q)
        return Biquad(b0: 1, b1: -2 * cw, b2: 1, a0: 1 + alpha, a1: -2 * cw, a2: 1 - alpha)
    }
}

// MARK: - フィルタ(ローパス/ハイパス/バンドパス/ノッチ)

final class FilterProcessor {
    private let coeff: Biquad
    private var stateL = BiquadState(), stateR = BiquadState()

    init(kind: AudioFx.FilterKind, filter: AudioFx.Filter, sr: Double) {
        let f = filter.freqOr(kind.defaultFreq), q = filter.qOr(kind.defaultQ)
        switch kind {
        case .lowPass: coeff = .lowPass(f0: f, q: q, sr: sr)
        case .highPass: coeff = .highPass(f0: f, q: q, sr: sr)
        case .bandPass: coeff = .bandPass(f0: f, q: q, sr: sr)
        case .notch: coeff = .notch(f0: f, q: q, sr: sr)
        }
    }

    /// 周波数応答(振幅の倍率)。試験・確認用。
    static func magnitude(kind: AudioFx.FilterKind, filter: AudioFx.Filter, at f: Double, sr: Double) -> Double {
        FilterProcessor(kind: kind, filter: filter, sr: sr).coeff.magnitude(at: f, sr: sr)
    }

    func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int) {
        for i in 0..<n {
            l[i] = Float(stateL.run(coeff, Double(l[i])))
            r[i] = Float(stateR.run(coeff, Double(r[i])))
        }
    }
}

// MARK: - パラメトリック EQ(5 バンド)

final class ParametricEQProcessor {
    private var bands: [Biquad] = []
    private var stateL: [BiquadState]
    private var stateR: [BiquadState]

    init(_ eq: AudioFx.ParametricEQ, sr: Double) {
        for (i, f) in AudioFx.ParametricEQ.frequencies.enumerated() where eq.gain(i) != 0 {
            bands.append(.peaking(f0: f, gainDb: eq.gain(i), q: 1, sr: sr))
        }
        stateL = Array(repeating: BiquadState(), count: bands.count)
        stateR = Array(repeating: BiquadState(), count: bands.count)
    }

    static func magnitude(_ eq: AudioFx.ParametricEQ, at f: Double, sr: Double) -> Double {
        var m = 1.0
        for (i, f0) in AudioFx.ParametricEQ.frequencies.enumerated() where eq.gain(i) != 0 {
            m *= Biquad.peaking(f0: f0, gainDb: eq.gain(i), q: 1, sr: sr).magnitude(at: f, sr: sr)
        }
        return m
    }

    func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int) {
        for b in 0..<bands.count {
            let c = bands[b]
            for i in 0..<n {
                l[i] = Float(stateL[b].run(c, Double(l[i])))
                r[i] = Float(stateR[b].run(c, Double(r[i])))
            }
        }
    }
}

// MARK: - ディストーション(tanh ソフトクリップ)

/// 入力を drive だけ増幅して tanh で潰す。フルスケール付近が 1 を超えないよう tanh(g) で割る。
/// drive 0 dB でも tanh の曲がりで軽く歪む(穏やかな飽和)。無音は無音のまま。
final class DistortionProcessor {
    private let g: Double, norm: Double, mix: Float, dry: Float

    init(_ d: AudioFx.Distortion, sr: Double) {
        g = pow(10, d.driveDb / 20)
        norm = tanh(g)
        mix = Float(d.mix); dry = 1 - mix
    }

    @inline(__always)
    func shape(_ x: Double) -> Double { tanh(g * x) / norm }

    func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int) {
        guard mix > 0 else { return }
        for i in 0..<n {
            l[i] = dry * l[i] + mix * Float(shape(Double(l[i])))
            r[i] = dry * r[i] + mix * Float(shape(Double(r[i])))
        }
    }
}

// MARK: - チューブ(非対称ソフトクリップ + 温かみローパス)

/// バイアスをずらした tanh で偶数倍音を出し、6.5 kHz の 1 次ローパスで高域を丸める(近似)。
final class TubeProcessor {
    private let g: Double, bias = 0.25, norm: Double, mix: Float, dry: Float
    private let lpCoef: Double
    private var lpL = 0.0, lpR = 0.0

    init(_ t: AudioFx.Tube, sr: Double) {
        g = pow(10, t.driveDb / 20)
        // 正側と負側のうち広い方で割る(非対称さは保ったまま、|出力| が 1 を超えないように)
        norm = max(tanh(g + bias) - tanh(bias), tanh(bias) - tanh(bias - g))
        mix = Float(t.mix); dry = 1 - mix
        lpCoef = 1 - exp(-2 * Double.pi * 6500 / sr)
    }

    @inline(__always)
    func shape(_ x: Double) -> Double { (tanh(g * x + bias) - tanh(bias)) / norm }

    func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int) {
        guard mix > 0 else { return }
        for i in 0..<n {
            lpL += lpCoef * (shape(Double(l[i])) - lpL)
            lpR += lpCoef * (shape(Double(r[i])) - lpR)
            l[i] = dry * l[i] + mix * Float(lpL)
            r[i] = dry * r[i] + mix * Float(lpR)
        }
    }
}

// MARK: - 変調ディレイ(コーラス / フランジャー / ビブラートの共通土台)

/// 循環バッファの読み位置を LFO で揺らす。左右で同じ LFO 位相を使い、読みは直線補間。
/// フィードバックはフランジャー用(0 なら単なる重ね)。wetOnly のとき原音を混ぜない(ビブラート)。
final class ModulatedDelayProcessor {
    private var bufL: [Float], bufR: [Float]
    private var idx = 0
    private var phase = 0.0
    private let phaseInc: Double
    private let base: Double, depthSamples: Double   // サンプル単位
    private let feedback: Float, mix: Float, dryGain: Float
    private let sr: Double

    init(baseSec: Double, depthSec: Double, rateHz: Double, feedback: Double, mix: Double, wetOnly: Bool, sr: Double) {
        self.sr = sr
        base = baseSec * sr
        depthSamples = depthSec * sr
        let size = max(16, Int(((baseSec + depthSec) * sr).rounded()) + 4)
        bufL = [Float](repeating: 0, count: size); bufR = bufL
        phaseInc = 2 * Double.pi * rateHz / sr
        self.feedback = Float(feedback)
        self.mix = Float(mix)
        dryGain = wetOnly ? 0 : 1 - self.mix
    }

    private func read(_ buf: [Float], at pos: Double) -> Float {
        let n = buf.count
        var p = pos.truncatingRemainder(dividingBy: Double(n))
        if p < 0 { p += Double(n) }
        let i0 = Int(p), frac = Float(p - Double(i0))
        let a = buf[i0], b = buf[(i0 + 1) % n]
        return a + (b - a) * frac
    }

    func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int) {
        guard mix > 0 else { return }
        let size = Double(bufL.count)
        for i in 0..<n {
            let delay = base + depthSamples * sin(phase)
            phase += phaseInc
            if phase > 2 * Double.pi { phase -= 2 * Double.pi }
            let rp = Double(idx) - delay
            let wetL = read(bufL, at: rp), wetR = read(bufR, at: rp)
            let inL = l[i], inR = r[i]
            bufL[idx] = inL + wetL * feedback
            bufR[idx] = inR + wetR * feedback
            l[i] = inL * dryGain + wetL * mix
            r[i] = inR * dryGain + wetR * mix
            idx += 1
            if Double(idx) >= size { idx = 0 }
        }
    }
}

// MARK: - フェイザー(オールパス 4 段)

/// 1 次オールパス 4 段の中心周波数を LFO で 200 Hz〜2.4 kHz の範囲で掃引する。
/// 係数は 16 サンプルごとに更新する(聞き分けられる滑らかさは保ち、計算を抑える)。
final class PhaserProcessor {
    private static let stages = 4
    private var x1L = [Double](repeating: 0, count: stages), y1L = [Double](repeating: 0, count: stages)
    private var x1R = [Double](repeating: 0, count: stages), y1R = [Double](repeating: 0, count: stages)
    private var fbL = 0.0, fbR = 0.0
    private var phase = 0.0
    private let phaseInc: Double
    private let depth: Double, feedback: Double, mix: Float, dry: Float
    private let sr: Double
    private var coeff = 0.0
    private var sinceUpdate = 1 << 30

    init(_ p: AudioFx.Phaser, sr: Double) {
        self.sr = sr
        phaseInc = 2 * Double.pi * p.rateHz / sr
        depth = p.depthValue
        feedback = 0.6 * p.depthValue
        mix = Float(p.mix); dry = 1 - mix
    }

    private func updateCoeff() {
        let s = 0.5 + 0.5 * sin(phase)
        let f = 200 * pow(12, s * depth)
        let t = tan(Double.pi * f / sr)
        coeff = (t - 1) / (t + 1)
    }

    private func runChannel(_ x: Double, x1: inout [Double], y1: inout [Double], fb: inout Double) -> Double {
        var v = x + feedback * fb
        for s in 0..<Self.stages {
            let y = coeff * v + x1[s] - coeff * y1[s]
            x1[s] = v; y1[s] = y; v = y
        }
        fb = v
        return v
    }

    func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int) {
        guard mix > 0 else { return }
        for i in 0..<n {
            if sinceUpdate >= 16 { updateCoeff(); sinceUpdate = 0 }
            sinceUpdate += 1
            phase += phaseInc
            if phase > 2 * Double.pi { phase -= 2 * Double.pi }
            let inL = l[i], inR = r[i]
            let wetL = runChannel(Double(inL), x1: &x1L, y1: &y1L, fb: &fbL)
            let wetR = runChannel(Double(inR), x1: &x1R, y1: &y1R, fb: &fbR)
            l[i] = dry * inL + mix * Float(wetL)
            r[i] = dry * inR + mix * Float(wetR)
        }
    }
}

// MARK: - トレモロ

final class TremoloProcessor {
    private var phase = 0.0
    private let phaseInc: Double
    private let depth: Double

    init(_ t: AudioFx.Tremolo, sr: Double) {
        phaseInc = 2 * Double.pi * t.rateHz / sr
        depth = t.depthValue
    }

    func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int) {
        for i in 0..<n {
            let g = Float(1 - depth * (0.5 + 0.5 * sin(phase)))
            phase += phaseInc
            if phase > 2 * Double.pi { phase -= 2 * Double.pi }
            l[i] *= g; r[i] *= g
        }
    }
}

// MARK: - ワウ / オートワウ

/// ピーキング(+14 dB、Q = 2.5)の周波数を動かす。係数は 16 サンプルごとに更新する。
/// 手動は position 固定、オートは左右最大の包絡(アタック 2 ms / リリース 80 ms)に
/// sensitivity で重みを付けて position にする。
final class WahProcessor {
    private var stateL = BiquadState(), stateR = BiquadState()
    private var coeff = Biquad.peaking(f0: 750, gainDb: 14, q: 2.5, sr: 48000)
    private var env = 0.0
    private let auto: Bool
    private let position: Double, sensitivity: Double
    private let sr: Double
    private let atkCoef: Double, relCoef: Double
    private var sinceUpdate = 1 << 30

    init(_ w: AudioFx.Wah, sr: Double) {
        self.sr = sr
        auto = w.auto
        position = w.positionValue
        sensitivity = w.sensitivityValue
        atkCoef = 1 - exp(-1 / (0.002 * sr))
        relCoef = 1 - exp(-1 / (0.080 * sr))
    }

    func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int) {
        for i in 0..<n {
            if auto {
                let peak = Double(max(abs(l[i]), abs(r[i])))
                env += (peak - env) * (peak > env ? atkCoef : relCoef)
            }
            if sinceUpdate >= 16 {
                let p = auto ? min(1, env * (1 + 4 * sensitivity)) : position
                coeff = .peaking(f0: AudioFx.Wah.frequency(forPosition: p), gainDb: 14, q: 2.5, sr: sr)
                sinceUpdate = 0
            }
            sinceUpdate += 1
            l[i] = Float(stateL.run(coeff, Double(l[i])))
            r[i] = Float(stateR.run(coeff, Double(r[i])))
        }
    }
}

// MARK: - エコー(高域が落ちていく繰り返し)

/// ディレイとの違い: フィードバック経路に 2.8 kHz の 1 次ローパスを入れ、
/// 繰り返すたびに音が柔らかく遠くなる。初回の繰り返しは原音に近い明るさ。
final class EchoProcessor {
    private var bufL: [Float], bufR: [Float]
    private var idx = 0
    private var lpL = 0.0, lpR = 0.0
    private let lpCoef: Double
    private let feedback: Float, mix: Float, dry: Float

    init(_ e: AudioFx.Echo, sr: Double) {
        let n = max(1, Int((e.timeSeconds * sr).rounded()))
        bufL = [Float](repeating: 0, count: n); bufR = bufL
        lpCoef = 1 - exp(-2 * Double.pi * 2800 / sr)
        feedback = Float(e.feedbackValue)
        mix = Float(e.mix); dry = 1 - mix
    }

    func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int) {
        guard mix > 0 else { return }
        for i in 0..<n {
            let dL = bufL[idx], dR = bufR[idx]
            lpL += lpCoef * (Double(dL) - lpL)
            lpR += lpCoef * (Double(dR) - lpR)
            bufL[idx] = l[i] + Float(lpL) * feedback
            bufR[idx] = r[i] + Float(lpR) * feedback
            l[i] = l[i] * dry + dL * mix
            r[i] = r[i] * dry + dR * mix
            idx += 1
            if idx >= bufL.count { idx = 0 }
        }
    }
}

// MARK: - 低音質化(量子化 + ダウンサンプルホールド)

final class LowQualityProcessor {
    private let step: Double
    private let hold: Int
    private var counter = 0
    private var heldL: Float = 0, heldR: Float = 0

    init(_ q: AudioFx.LowQuality, sr: Double) {
        step = pow(2, 1 - Double(q.bitsValue))
        hold = max(1, q.downsampleValue)
    }

    private func quantize(_ x: Float) -> Float {
        let v = (Double(x) / step + 0.5).rounded(.down) * step
        return Float(min(1, max(-1, v)))
    }

    func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int) {
        for i in 0..<n {
            if counter == 0 { heldL = quantize(l[i]); heldR = quantize(r[i]) }
            l[i] = heldL; r[i] = heldR
            counter += 1
            if counter >= hold { counter = 0 }
        }
    }
}

// MARK: - ロボット化(リング変調)

/// 入力に搬送波(正弦波)を掛ける古典的なリング変調。元の周波数成分が消え、
/// 入力±搬送波の側帯波だけが残るため金属的な声になる。YMM4 の内部方式とは異なる近似。
final class RobotProcessor {
    private var phase = 0.0
    private let phaseInc: Double
    private let mix: Float, dry: Float

    init(_ r: AudioFx.Robot, sr: Double) {
        phaseInc = 2 * Double.pi * r.frequencyHz / sr
        mix = Float(r.mix); dry = 1 - mix
    }

    func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int) {
        guard mix > 0 else { return }
        for i in 0..<n {
            let carrier = Float(sin(phase))
            phase += phaseInc
            if phase > 2 * Double.pi { phase -= 2 * Double.pi }
            l[i] = dry * l[i] + mix * l[i] * carrier
            r[i] = dry * r[i] + mix * r[i] * carrier
        }
    }
}

// MARK: - 拡張チェーン(順番固定)

/// 拡張エフェクトの連なり。順番: ハイパス → ローパス → バンドパス → ノッチ → パラメトリックEQ
/// → ディストーション → チューブ → ワウ → コーラス → フランジャー → フェイザー → トレモロ
/// → ビブラート → エコー → ロボット → 低音質化。AudioFxChain の中(リミッターの前)で使う。
final class ExtendedChain {
    private let highPass: FilterProcessor?
    private let lowPass: FilterProcessor?
    private let bandPass: FilterProcessor?
    private let notch: FilterProcessor?
    private let equalizer: ParametricEQProcessor?
    private let distortion: DistortionProcessor?
    private let tube: TubeProcessor?
    private let wah: WahProcessor?
    private let chorus: ModulatedDelayProcessor?
    private let flanger: ModulatedDelayProcessor?
    private let phaser: PhaserProcessor?
    private let tremolo: TremoloProcessor?
    private let vibrato: ModulatedDelayProcessor?
    private let echo: EchoProcessor?
    private let robot: RobotProcessor?
    private let lowQuality: LowQualityProcessor?

    init(_ x: AudioFx.Extended, sr: Double) {
        func fp(_ kind: AudioFx.FilterKind) -> FilterProcessor? {
            guard let f = x.filter(kind), f.isActive else { return nil }
            return FilterProcessor(kind: kind, filter: f, sr: sr)
        }
        highPass = fp(.highPass); lowPass = fp(.lowPass); bandPass = fp(.bandPass); notch = fp(.notch)
        equalizer = x.equalizer.flatMap { $0.isActive ? ParametricEQProcessor($0, sr: sr) : nil }
        distortion = x.distortion.flatMap { $0.isActive ? DistortionProcessor($0, sr: sr) : nil }
        tube = x.tube.flatMap { $0.isActive ? TubeProcessor($0, sr: sr) : nil }
        wah = x.wah.flatMap { $0.isActive ? WahProcessor($0, sr: sr) : nil }
        chorus = x.chorus.flatMap { c in c.isActive ? ModulatedDelayProcessor(baseSec: 0.018, depthSec: 0.007 * c.depthValue, rateHz: c.rateHz, feedback: 0, mix: c.mix, wetOnly: false, sr: sr) : nil }
        flanger = x.flanger.flatMap { f in f.isActive ? ModulatedDelayProcessor(baseSec: 0.0025, depthSec: 0.0022 * f.depthValue, rateHz: f.rateHz, feedback: f.feedbackValue, mix: f.mix, wetOnly: false, sr: sr) : nil }
        phaser = x.phaser.flatMap { $0.isActive ? PhaserProcessor($0, sr: sr) : nil }
        tremolo = x.tremolo.flatMap { $0.isActive ? TremoloProcessor($0, sr: sr) : nil }
        vibrato = x.vibrato.flatMap { v in v.isActive ? ModulatedDelayProcessor(baseSec: 0.012, depthSec: min(0.010, v.depthMs / 1000), rateHz: v.rateHz, feedback: 0, mix: 1, wetOnly: true, sr: sr) : nil }
        echo = x.echo.flatMap { $0.isActive ? EchoProcessor($0, sr: sr) : nil }
        robot = x.robot.flatMap { $0.isActive ? RobotProcessor($0, sr: sr) : nil }
        lowQuality = x.lowQuality.flatMap { $0.isActive ? LowQualityProcessor($0, sr: sr) : nil }
    }

    func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int) {
        highPass?.process(l, r, n)
        lowPass?.process(l, r, n)
        bandPass?.process(l, r, n)
        notch?.process(l, r, n)
        equalizer?.process(l, r, n)
        distortion?.process(l, r, n)
        tube?.process(l, r, n)
        wah?.process(l, r, n)
        chorus?.process(l, r, n)
        flanger?.process(l, r, n)
        phaser?.process(l, r, n)
        tremolo?.process(l, r, n)
        vibrato?.process(l, r, n)
        echo?.process(l, r, n)
        robot?.process(l, r, n)
        lowQuality?.process(l, r, n)
    }
}
