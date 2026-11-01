import Foundation

// MARK: - ビートの検出(音楽のテンポとビートの位置)
//
// 入力は無音検出と同じ 10 ms 単位の音量列(`LevelProfile`)。決定的な処理だけで、乱数・時刻には頼らない。
// 1) オンセット: 10 ms ごとの音量の増え方(dB の正の差分)を取る(エネルギーフラックス)。
// 2) テンポ: オンセットの自己相関で 60〜200 BPM の周期を選ぶ(同じ強さの候補は短い周期を取る = 倍のテンポを避ける)。
// 3) 位置: 周期を前後 4% の範囲で細かく動かし、各位相でビートの上のオンセットの和が最大になるものを取る。
// 結果は「ビートの格子」(テンポと、測った範囲の頭からのビートの時刻)。

public struct BeatGrid: Equatable, Sendable {
    /// テンポ(BPM)。
    public var bpm: Double
    /// ビートの時刻(秒。測った範囲の頭からの時刻、昇順)。
    public var beats: [Double]
    /// 信頼度(0〜1)。周期の自己相関の強さを、ゼロ遅れの強さで割ったもの。低いときは拍が取れていない。
    public var confidence: Double

    public init(bpm: Double, beats: [Double], confidence: Double) {
        self.bpm = bpm; self.beats = beats; self.confidence = confidence
    }
}

public enum BeatDetector {
    public static let minBPM = 60.0
    public static let maxBPM = 200.0
    /// オンセットの 1 窓の長さ(秒)。無音検出の窓と同じ。
    public static let hop = LevelProfile.windowSeconds
    /// 位相の刻み(秒)。ビートの位置の精度。
    static let phaseStep = 0.004
    /// 周期の細かい探索の刻み(秒)と範囲(自己相関の周期の前後の割合)。
    static let periodStep = 0.0005
    static let periodSpread = 0.04
    /// これ以上の周期の候補(自己相関の値が最大の何割以上)のうち、最も短いものを取る。
    static let octaveRatio = 0.85

    /// 無音検出の音量列からビートを求める。拍が取れない(無音・短すぎ)ときは nil。
    public static func analyze(profile: LevelProfile) -> BeatGrid? {
        analyze(levels: profile.levels, duration: profile.duration)
    }

    /// 窓ごとの dB 列と、測った長さ(秒)からビートを求める。
    public static func analyze(levels: [Float], duration: Double) -> BeatGrid? {
        let env = onsetEnvelope(levels)
        let n = env.count
        let minLag = Int((60 / maxBPM / hop).rounded(.down))
        let maxLag = Int((60 / minBPM / hop).rounded(.up))
        guard n > 2 * maxLag, env.contains(where: { $0 > 0 }) else { return nil }

        // 平均を引いてから自己相関を取る(定数の成分で周期が見えなくなるのを防ぐ)
        let mean = env.reduce(0, +) / Double(n)
        let x = env.map { $0 - mean }
        var energy = 0.0
        for v in x { energy += v * v }
        guard energy > 0 else { return nil }
        let r0 = energy / Double(n)

        var corr = [Double](repeating: 0, count: maxLag + 2)
        for lag in minLag...maxLag {
            var s = 0.0
            for i in 0..<(n - lag) { s += x[i] * x[i + lag] }
            corr[lag] = s / Double(n - lag)
        }
        var peak = -Double.infinity
        for lag in minLag...maxLag { peak = max(peak, corr[lag]) }
        guard peak > 0 else { return nil }
        // 最大の何割以上の極大のうち、最も短い周期を取る(倍のテンポを避ける)
        var lag0 = minLag
        for lag in minLag...maxLag {
            let isPeak = corr[lag] >= corr[max(minLag, lag - 1)] && corr[lag] >= corr[min(maxLag, lag + 1)]
            if isPeak && corr[lag] >= octaveRatio * peak { lag0 = lag; break }
        }

        // 周期を細かく探し、位相を全部試して、ビートの上のオンセットの和が最大の組を取る
        let basePeriod = Double(lag0) * hop
        let lo = basePeriod * (1 - periodSpread), hi = basePeriod * (1 + periodSpread)
        var bestScore = -Double.infinity, bestPeriod = basePeriod, bestPhase = 0.0
        let total = Double(n) * hop
        var period = lo
        while period <= hi + 1e-12 {
            var phase = 0.0
            while phase < period - 1e-12 {
                var s = 0.0
                var t = phase
                while t < total {
                    s += env[min(n - 1, Int((t / hop).rounded()))]
                    t += period
                }
                // 同点は、周期が基準に近く・位相が小さい方を取る(決定的にするため)
                if s > bestScore + 1e-9 { bestScore = s; bestPeriod = period; bestPhase = phase }
                phase += phaseStep
            }
            period += periodStep
        }

        var beats: [Double] = []
        var t = bestPhase
        while t < min(duration, total) - 1e-9 {
            beats.append(t)
            t += bestPeriod
        }
        guard beats.count >= 2 else { return nil }
        let confidence = min(1, max(0, corr[lag0] / r0))
        return BeatGrid(bpm: 60 / bestPeriod, beats: beats, confidence: confidence)
    }

    /// 窓ごとの音量の増え方(dB の正の差分)。最初の窓は 0。
    public static func onsetEnvelope(_ levels: [Float]) -> [Double] {
        var env = [Double](repeating: 0, count: levels.count)
        guard levels.count > 1 else { return env }
        for i in 1..<levels.count {
            env[i] = max(0, Double(levels[i]) - Double(levels[i - 1]))
        }
        return env
    }

    /// 無音検出と同じ条件で、ビートを探せる素材か(音が出る・速度や逆再生が無い)。
    public static func supports(_ c: Clip) -> Bool {
        SilenceDetector.supports(c)
    }

    /// ビートの時刻(クリップの頭からの秒)を、プロジェクトの時刻に直す。クリップの長さの外は捨てる。
    public static func projectTimes(_ grid: BeatGrid, clip c: Clip) -> [Double] {
        grid.beats.filter { $0 >= 0 && $0 < c.duration }.map { c.start + $0 }
    }
}
