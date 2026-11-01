import Foundation
import AVFoundation

/// ラウドネス計測(ITU-R BS.1770-4 / EBU R128 の考え方)。48 kHz・2 チャンネルの Float32 を流し込む。
/// - K 特性フィルタ(前段のシェルフ + RLB のハイパス)は `LevelMeter` と同じ係数を使う。
/// - 100 ms ごとに二乗平均を取り、400 ms(4 区切り)の「モーメンタリ」と 3 s(30 区切り)の「ショートターム」を作る。
/// - 統合ラウドネスは絶対ゲート −70 LUFS と、相対ゲート(絶対ゲート後の平均 −10 LU)をかけて平均する。
/// - 真のピークは 4 倍のオーバーサンプリング(窓付き sinc の多相フィルタ)で探す。
/// 注意: 公式の適合テスト音源での検証は行っていない(合成信号の理論値との比較のみ)。
public struct LoudnessReport: Equatable, Sendable {
    /// 統合ラウドネス(LUFS)。ゲートを通る区間が無いときは −∞。
    public var integrated: Double
    /// ショートタームの最大(LUFS)。3 s 未満なら −∞。
    public var shortTermMax: Double
    /// 真のピーク(dBTP)。無音は −∞。
    public var truePeakDb: Double
    /// サンプルのピーク(dBFS)。無音は −∞。
    public var samplePeakDb: Double
    /// 測った長さ(秒)。
    public var duration: Double

    /// YouTube の目安(−14 LUFS)との差(dB)。統合が −∞ なら nil。自動で音量は変えない(目安として見せるだけ)。
    public func differenceToYouTube() -> Double? {
        guard integrated.isFinite else { return nil }
        return integrated - LoudnessMeter.youTubeTargetLUFS
    }
}

public final class LoudnessMeter {
    /// YouTube の推奨の目安(LUFS)。
    public static let youTubeTargetLUFS = -14.0
    static let sampleRate = 48_000.0
    private static let hopSamples = 4_800          // 100 ms
    private static let momentaryHops = 4           // 400 ms
    private static let shortTermHops = 30          // 3 s
    private static let absoluteGate = -70.0
    private static let relativeOffset = -10.0

    private var pre = (l: BiquadState(), r: BiquadState())
    private var rlb = (l: BiquadState(), r: BiquadState())
    private var hopSum = 0.0
    private var hopCount = 0
    private var hops: [Double] = []            // 100 ms ごとの、両チャンネルの K 特性後の二乗平均の和
    private var truePeakL = TruePeakDetector()
    private var truePeakR = TruePeakDetector()
    private var samplePeak: Float = 0
    private var frames = 0

    public init() {}

    /// 同じ長さの左右のブロックを流す。
    public func add(_ l: UnsafePointer<Float>, _ r: UnsafePointer<Float>, _ n: Int) {
        for i in 0..<n {
            let xl = Double(l[i]), xr = Double(r[i])
            samplePeak = max(samplePeak, abs(l[i]), abs(r[i]))
            truePeakL.push(xl)
            truePeakR.push(xr)
            let yl = rlb.l.run(LevelMeter.rlbFilter, pre.l.run(LevelMeter.preFilter, xl))
            let yr = rlb.r.run(LevelMeter.rlbFilter, pre.r.run(LevelMeter.preFilter, xr))
            hopSum += yl * yl + yr * yr
            hopCount += 1
            if hopCount == Self.hopSamples {
                hops.append(hopSum / Double(hopCount))
                hopSum = 0; hopCount = 0
            }
        }
        frames += n
    }

    public func finish() -> LoudnessReport {
        let tp = max(truePeakL.peak, truePeakR.peak)
        return LoudnessReport(
            integrated: Self.integratedLoudness(hops: hops),
            shortTermMax: Self.shortTermMax(hops: hops),
            truePeakDb: tp > 0 ? 20 * log10(tp) : -.infinity,
            samplePeakDb: samplePeak > 0 ? 20 * log10(Double(samplePeak)) : -.infinity,
            duration: Double(frames) / Self.sampleRate)
    }

    /// 二乗平均(和)から LUFS へ。
    static func lufs(_ energy: Double) -> Double { energy > 0 ? -0.691 + 10 * log10(energy) : -.infinity }

    /// 400 ms のモーメンタリ(区切りごとの平均)の列。
    static func momentary(hops: [Double]) -> [Double] {
        guard hops.count >= momentaryHops else { return [] }
        return (momentaryHops - 1..<hops.count).map { i in
            hops[(i - momentaryHops + 1)...i].reduce(0, +) / Double(momentaryHops)
        }
    }

    static func integratedLoudness(hops: [Double]) -> Double {
        let m = momentary(hops: hops)
        let absKept = m.filter { lufs($0) >= absoluteGate }
        guard !absKept.isEmpty else { return -.infinity }
        let relGate = lufs(absKept.reduce(0, +) / Double(absKept.count)) + relativeOffset
        let kept = m.filter { lufs($0) >= relGate }
        guard !kept.isEmpty else { return -.infinity }
        return lufs(kept.reduce(0, +) / Double(kept.count))
    }

    static func shortTermMax(hops: [Double]) -> Double {
        guard hops.count >= shortTermHops else { return -.infinity }
        var best = -Double.infinity
        for i in (shortTermHops - 1)..<hops.count {
            let mean = hops[(i - shortTermHops + 1)...i].reduce(0, +) / Double(shortTermHops)
            best = max(best, lufs(mean))
        }
        return best
    }
}

/// 4 倍オーバーサンプリングの真のピーク検出(1 チャンネル・ストリーミング)。
struct TruePeakDetector {
    static let factor = 4
    static let taps = 12                       // 位相あたりの係数の数
    /// 位相ごとの係数(`factor` 本)。窓付き sinc を 4 位相に分けるので、各位相の直流ゲインはほぼ 1。
    static let phases: [[Double]] = {
        let n = factor * taps
        let center = Double(n - 1) / 2
        var proto = [Double](repeating: 0, count: n)
        for k in 0..<n {
            let x = (Double(k) - center) / Double(factor)
            let sinc = x == 0 ? 1 : sin(Double.pi * x) / (Double.pi * x)
            let w = 0.5 - 0.5 * cos(2 * Double.pi * Double(k) / Double(n - 1))   // Hann
            proto[k] = sinc * w
        }
        return (0..<factor).map { p in (0..<taps).map { j in proto[p + factor * j] } }
    }()

    private var history = [Double](repeating: 0, count: taps)
    private var head = 0
    private(set) var peak = 0.0

    /// 1 サンプル入れると、4 位相ぶんの出力の絶対値の最大を `peak` に反映する。
    mutating func push(_ x: Double) {
        history[head] = x
        for p in 0..<Self.factor {
            var acc = 0.0
            var idx = head
            let c = Self.phases[p]
            for j in 0..<Self.taps {
                acc += c[j] * history[idx]
                idx = idx == 0 ? Self.taps - 1 : idx - 1
            }
            peak = max(peak, abs(acc))
        }
        head = (head + 1) % Self.taps
    }
}

/// 書き出しと同じミックスダウンを測る(一時ファイルは測ったら消す)。
public enum LoudnessAnalysis {
    /// プロジェクトの全体(または範囲)の音を測る。音声が無いときは nil。
    public static func measure(project: Project, range: ExportRange? = nil) throws -> LoudnessReport? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("moviecut-loudness-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let mix = try AudioMixer.mixdownDetailed(project: project, to: url, range: range)
        guard mix.sourceCount > 0 else { return nil }
        return try measureFile(url)
    }

    /// 48 kHz ステレオ Float32 の音声ファイルを測る(ミックスダウンの出力形式)。
    public static func measureFile(_ url: URL) throws -> LoudnessReport {
        let file = try AVAudioFile(forReading: url)
        let fmt = file.processingFormat
        guard fmt.sampleRate == LoudnessMeter.sampleRate, fmt.channelCount == 2, fmt.commonFormat == .pcmFormatFloat32 else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        let meter = LoudnessMeter()
        let chunk: AVAudioFrameCount = 8192
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunk) else { throw CocoaError(.fileReadUnknown) }
        while file.framePosition < file.length {
            try file.read(into: buf, frameCount: min(chunk, AVAudioFrameCount(file.length - file.framePosition)))
            guard buf.frameLength > 0, let c = buf.floatChannelData else { break }
            meter.add(c[0], c[1], Int(buf.frameLength))
        }
        return meter.finish()
    }
}
