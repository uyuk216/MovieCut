import Foundation
import CoreImage

/// フィルム風のハイライト圧縮(明るい部分だけを、白に届かない手前へなめらかに寄せる純粋な計算)。
/// 0〜`knee` は変えない。`knee` を越えると、残りの幅(1 − knee)を指数で詰める。接線は knee で連続し、出力は 1 未満。
public enum HighlightRolloff {
    public static let defaultKnee = 0.8

    /// 膝の位置を 0〜0.99 に直す(壊れた値は既定)。
    public static func clampKnee(_ k: Double) -> Double {
        guard k.isFinite else { return defaultKnee }
        return min(max(k, 0), 0.99)
    }

    /// 1 つの輝度(0〜1)を圧縮する。範囲外は 0〜1 に切り詰めてから計算する。非有限の値は 0。
    public static func apply(_ v: Double, knee: Double = defaultKnee) -> Double {
        guard v.isFinite else { return 0 }
        let x = min(max(v, 0), 1)
        let k = clampKnee(knee)
        guard x > k else { return x }
        let room = 1 - k
        return k + room * (1 - exp(-(x - k) / room))
    }

    /// 0〜1 を `size` 段に区切った変換表(両端を含む)。`size` は 2 以上に直す。
    public static func table(size: Int = 256, knee: Double = defaultKnee) -> [Double] {
        let n = max(2, size)
        return (0..<n).map { i in apply(Double(i) / Double(n - 1), knee: knee) }
    }
}

extension HighlightRolloff {
    /// CIColorCube 用の 1 辺の数(赤・緑・青は独立に変わるので、各軸を同じ変換表で引けば足りる)。
    public static let cubeDimension = 17

    /// 3D の色表(RGBA の Float × dimension³)。各チャンネルに同じ圧縮をかける(チャンネルは混ぜない)。
    public static func cubeData(knee: Double = defaultKnee) -> Data {
        let n = cubeDimension
        let curve: [Float] = (0..<n).map { i in Float(apply(Double(i) / Double(n - 1), knee: knee)) }
        var floats = [Float]()
        floats.reserveCapacity(n * n * n * 4)
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    floats.append(curve[r]); floats.append(curve[g]); floats.append(curve[b]); floats.append(1)
                }
            }
        }
        return floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
