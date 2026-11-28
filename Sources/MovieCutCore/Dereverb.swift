import Foundation
import Accelerate

// MARK: - 反響除去(古典 DSP・決定的)
//
// 部屋の残響は「直接音のあとに、指数的に小さくなりながら遅れて続く成分(遅延成分)」。
// STFT 領域で、各周波数の遅延成分のパワーを推定して引く(Lebart / Habets 系のスペクトル減算)。
//   1. `SpectralDenoise` と同じ STFT(窓 2048・Hann・ホップ 512・75% 重ね)に乗せる。
//   2. 遅延成分の推定: late[k] = 10^(−6·Δ/T60) · P[t−D][k]
//      (D フレーム前の観測パワーが、残響の減衰ぶんだけ小さくなって今に重なる。Δ = D·ホップ/サンプルレート、T60 は想定の残響時間)。
//   3. ゲイン = √clamp(1 − γ·late/P, 床, 1)。パワーは隣の 3 bin で平滑化。下がるのはゆっくり(ぶつぶつ切れないように)。
//   4. 左右はゲインを共有する(左右のパワー平均から 1 本のゲインを作り両方へ掛ける)ので、定位(左右の比)は変わらない。
// 強さ s(0〜1)で γ = 4·s、床 = −(6 + 24·s) dB。s = 0 は処理を挟まず素通し(バイパスとビット一致)。乱数なし。
// 限界: 学習型ではない。想定 T60 は固定(0.5 秒)。強い残響・音楽・持続音では、直接音まで少し削って不自然になり得る。

enum Dereverb {
    static let delayFrames = 6          // D: 約 64 ms(48 kHz)
    static let assumedT60 = 0.5         // 秒
    static let releasePerFrame: Float = 0.8

    struct Params {
        let gamma: Float
        let floorMask: Float
        let decay: Float                // 10^(−6Δ/T60)(パワー)
        init(strength: Double, sampleRate sr: Double) {
            let s = Float(AudioFx.clampDereverb(strength))
            gamma = 4 * s
            floorMask = powf(10, -(6 + 24 * s) / 10)
            let delta = Double(Dereverb.delayFrames * SpectralDenoise.hop) / max(sr, 1)
            decay = Float(pow(10, -6 * delta / Dereverb.assumedT60))
        }
    }

    /// 左右でゲインを共有する STFT 処理器。
    final class Processor: StereoFrameProcessor {
        let trL = SpectralDenoise.Transform(), trR = SpectralDenoise.Transform()
        let p: Params
        let half = SpectralDenoise.fftSize / 2
        var pL: [Float], pR: [Float], power: [Float], smoothed: [Float], gain: [Float], prevGain: [Float]
        var history: [[Float]]          // 過去 D フレームの平滑化パワー(リング)
        var head = 0
        var outL: [Float], outR: [Float]
        init(params: Params) {
            p = params
            let z = [Float](repeating: 0, count: half)
            pL = z; pR = z; power = z; smoothed = z; gain = z
            prevGain = [Float](repeating: 1, count: half)
            history = [[Float]](repeating: z, count: Dereverb.delayFrames)
            outL = [Float](repeating: 0, count: SpectralDenoise.fftSize); outR = outL
        }

        func process(left: UnsafePointer<Float>, right: UnsafePointer<Float>) {
            trL.forward(left); trR.forward(right)
            trL.power(into: &pL); trR.power(into: &pR)
            for k in 0..<half { power[k] = 0.5 * (pL[k] + pR[k]) }
            for k in 0..<half {
                let a = power[max(0, k - 1)], c = power[min(half - 1, k + 1)]
                smoothed[k] = 0.25 * a + 0.5 * power[k] + 0.25 * c
            }
            // history[head] は D フレーム前のパワー(まだ上書きしていない)
            for k in 0..<half {
                let late = p.decay * history[head][k]
                var m = smoothed[k] > 0 ? 1 - p.gamma * late / smoothed[k] : 1
                m = min(1, max(p.floorMask, m))
                gain[k] = max(m.squareRoot(), prevGain[k] * Dereverb.releasePerFrame)
            }
            history[head] = smoothed
            head = (head + 1) % Dereverb.delayFrames
            for k in 0..<half {
                trL.re[k] *= gain[k]; trL.im[k] *= gain[k]
                trR.re[k] *= gain[k]; trR.im[k] *= gain[k]
            }
            let nyq = gain[half - 1] / max(gain[0], 1e-9)   // 実際は Nyquist(SpectralDenoise と同じ作法)
            trL.im[0] *= nyq; trR.im[0] *= nyq
            swap(&prevGain, &gain)
            outL.withUnsafeMutableBufferPointer { trL.inverse(into: $0.baseAddress!) }
            outR.withUnsafeMutableBufferPointer { trR.inverse(into: $0.baseAddress!) }
            for i in 0..<SpectralDenoise.fftSize { outL[i] *= trL.window[i]; outR[i] *= trL.window[i] }
        }
    }

    /// 強さ 0 なら入力をそのまま返す(素通し)。
    static func makeSource(inner: PCMSource, strength: Double, sampleRate sr: Double) -> PCMSource {
        guard AudioFx.clampDereverb(strength) > 0 else { return inner }
        return SpectralDenoiseSource(inner: inner, processor: Processor(params: Params(strength: strength, sampleRate: sr)))
    }

    /// 配列をまとめて処理する(テスト・CLI 用)。
    static func process(left: [Float], right: [Float], sampleRate sr: Double, strength: Double) -> (left: [Float], right: [Float]) {
        let n = min(left.count, right.count)
        guard AudioFx.clampDereverb(strength) > 0, n > 0 else { return (left, right) }
        let src = makeSource(inner: SpectralDenoise.ArraySource(Array(left[0..<n]), Array(right[0..<n])), strength: strength, sampleRate: sr)
        var l = [Float](repeating: 0, count: n), r = [Float](repeating: 0, count: n)
        var done = 0
        while done < n {
            let got = l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
                src.read(left: lp.baseAddress! + done, right: rp.baseAddress! + done, frames: min(4096, n - done)) } }
            if got <= 0 { break }
            done += got
        }
        return (l, r)
    }
}
