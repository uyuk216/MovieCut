import Foundation
import Accelerate

// MARK: - 周波数スペクトルの解析(音声ビジュアライザの「スペクトル」モード)
//
// 合成音声(または選んだ 1 つの音声クリップ)を 1/60 秒ごとに FFT(Accelerate vDSP)にかけ、
// 40 Hz〜16 kHz を対数に等分した N 本の帯にまとめる。帯の値は 0〜1(−60 dBFS 〜 0 dBFS の線形)。
// 平滑化(上がるのは速く・下がるのはゆっくり)は解析のときに前から順に掛けておく。
// 描画は「時刻 → 配列の添字」を引くだけなので、シークしても・書き出しでも同じ画になる(決定的。乱数なし)。

public enum SpectrumAnalyzer {
    public static let fftSize = 2048
    public static let frameRate = 60.0
    public static let minFrequency = 40.0
    public static let maxFrequency = 16000.0
    /// 0 dBFS から何 dB 下までを 0〜1 に写すか。
    public static let rangeDb = 60.0
    /// 上がるときの追従(1 = 即時)と、下がるときの 1 コマあたりの残り(1/60 秒ごと)。
    public static let attack: Float = 0.7
    public static let decay: Float = 0.86

    /// 周波数 f(Hz)が入る帯の番号(0..<count)。範囲の外は端の帯。
    public static func bandIndex(for f: Double, count: Int) -> Int {
        guard count > 0, f > 0 else { return 0 }
        let x = log(f / minFrequency) / log(maxFrequency / minFrequency) * Double(count)
        return min(max(Int(floor(x)), 0), count - 1)
    }

    /// 帯の境目の周波数(count + 1 個)。
    public static func bandEdges(count: Int) -> [Double] {
        (0...count).map { minFrequency * pow(maxFrequency / minFrequency, Double($0) / Double(count)) }
    }

    /// 帯ごとの値(0〜1)。`out` は frames × count の平らな配列(コマ k の帯 b は `out[k * count + b]`)。
    /// `samples` は 1 チャンネル(モノ)、サンプルレート `sr`。コマ k は時刻 k/60 秒を中心にした 2048 点。
    public static func analyze(mono samples: [Float], sampleRate sr: Double, count: Int, frames: Int) -> [Float] {
        let n = fftSize, half = n / 2
        guard count > 0, frames > 0, sr > 0, let setup = vDSP_create_fftsetup(11, FFTRadix(FFT_RADIX2)) else {
            return [Float](repeating: 0, count: max(0, count * frames))
        }
        defer { vDSP_destroy_fftsetup(setup) }
        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)
        // 帯 → bin の範囲(帯が bin より狭いときは最寄りの 1 つ)
        let binHz = sr / Double(n)
        let edges = bandEdges(count: count)
        var ranges: [(Int, Int)] = []
        for b in 0..<count {
            var lo = Int((edges[b] / binHz).rounded(.up)), hi = Int((edges[b + 1] / binHz).rounded(.up))   // [lo, hi)
            lo = min(max(lo, 1), half - 1)
            if hi <= lo {
                let c = Int((((edges[b] * edges[b + 1]).squareRoot()) / binHz).rounded())
                lo = min(max(c, 1), half - 1); hi = lo + 1
            }
            ranges.append((lo, min(hi, half)))
        }
        var out = [Float](repeating: 0, count: count * frames)
        var prev = [Float](repeating: 0, count: count)
        var frame = [Float](repeating: 0, count: n)
        var re = [Float](repeating: 0, count: half), im = [Float](repeating: 0, count: half)
        var mag = [Float](repeating: 0, count: half)
        let norm = Float(2.0 / Double(n))   // zrip の出力は DFT の 2 倍 = A·n/2。振幅 1 の正弦波が 1 になる
        for k in 0..<frames {
            let center = Int((Double(k) / frameRate * sr).rounded())
            let start = center - half
            for i in 0..<n {
                let j = start + i
                frame[i] = (j >= 0 && j < samples.count) ? samples[j] : 0
            }
            vDSP.multiply(frame, window, result: &frame)
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    frame.withUnsafeBufferPointer { fp in
                        fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                            vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, 11, FFTDirection(FFT_FORWARD))
                }
            }
            for i in 0..<half { mag[i] = (re[i] * re[i] + im[i] * im[i]).squareRoot() * norm }
            for b in 0..<count {
                var m: Float = 0
                for i in ranges[b].0..<ranges[b].1 { m = max(m, mag[i]) }
                let db = 20 * log10(Double(max(m, 1e-9)))
                let v = Float(min(1, max(0, (db + rangeDb) / rangeDb)))
                // 平滑化: 上がるときは attack、下がるときは decay の残り
                let p = prev[b]
                let s = v >= p ? p + (v - p) * attack : max(v, p * decay)
                prev[b] = s
                out[k * count + b] = s
            }
        }
        return out
    }
}
