import Foundation

// MARK: - 音による同期(複数カメラの音の合わせ)
//
// 2 本の音(同じ場面を録った音)の、ずれの量を相互相関で求める純粋な計算。ファイルの読み出しは呼び出し側。
// 長い音は `envelope` で包絡(窓ごとの RMS)にしてから合わせると速い。

public enum AudioSync {
    /// 窓ごとの RMS(包絡)。`window` は 1 以上。端の半端な窓は捨てる。
    public static func envelope(_ samples: [Float], window: Int) -> [Float] {
        let w = max(1, window)
        guard samples.count >= w else { return [] }
        var out: [Float] = []
        out.reserveCapacity(samples.count / w)
        var i = 0
        while i + w <= samples.count {
            var sum: Float = 0
            for k in i..<(i + w) { sum += samples[k] * samples[k] }
            out.append((sum / Float(w)).squareRoot())
            i += w
        }
        return out
    }

    /// `target` が `reference` より何サンプル後ろにずれているかを求める(正なら target が後ろ。`target[n] ≈ reference[n - lag]`)。
    /// 平均を引いて正規化した相互相関を、-maxLag...maxLag の範囲で探す。`score` は −1〜1(1 に近いほど一致)。
    /// 重なりが 2 サンプル未満、または片方が無音なら nil。
    public static func lag(reference: [Float], target: [Float], maxLag: Int) -> (lag: Int, score: Double)? {
        let n = min(reference.count, target.count)
        guard n >= 2 else { return nil }
        let r = center(Array(reference.prefix(n)))
        let t = center(Array(target.prefix(n)))
        let limit = max(0, min(maxLag, n - 2))
        var best: (lag: Int, score: Double)?
        for lag in -limit...limit {
            // target[k] と reference[k - lag] が両方ある k の範囲
            let lo = max(0, lag), hi = min(n, n + lag)
            guard hi - lo >= 2 else { continue }
            var dot = 0.0, er = 0.0, et = 0.0
            for k in lo..<hi {
                let a = Double(r[k - lag]), b = Double(t[k])
                dot += a * b; er += a * a; et += b * b
            }
            guard er > 1e-12, et > 1e-12 else { continue }
            let score = dot / (er * et).squareRoot()
            if best == nil || score > best!.score || (score == best!.score && abs(lag) < abs(best!.lag)) {
                best = (lag, score)
            }
        }
        return best
    }

    /// 秒に直す(サンプルレートから)。
    public static func seconds(lag: Int, sampleRate: Double) -> Double {
        guard sampleRate > 0, sampleRate.isFinite else { return 0 }
        return Double(lag) / sampleRate
    }

    private static func center(_ x: [Float]) -> [Float] {
        guard !x.isEmpty else { return x }
        let mean = x.reduce(0, +) / Float(x.count)
        return x.map { $0 - mean }
    }
}
