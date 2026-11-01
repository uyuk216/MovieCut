import Foundation

/// カラーホイール(持ち上げ・ガンマ・ゲイン)の計算。色相(角度)と強さ(0〜1)から、3D カラールックアップ表を作る。
///
/// 1 つのホイールは、赤・緑・青それぞれへの効き方を `cos(角度 − 各チャンネルの位相)` で決める(赤が角度 0 のとき赤を強める)。
/// - 持ち上げ(リフト): 暗い部分を持ち上げる。 out = in + L·(1 − in)、L = 0.25·強さ·効き
/// - ゲイン: 明るい部分を倍率で動かす。 out = in·G、G = 1 + 0.5·強さ·効き
/// - ガンマ: 中間調を動かす。 out = in^(1/γ)、γ = exp(0.5·強さ·効き)
/// 順に、持ち上げ → ゲイン → ガンマ を当てる。強さが 0 のホイールは何もしない(恒等)。
public enum ColorWheels {
    /// 色のホイール 1 つ分(角度は度・強さは 0〜1)。
    public struct Wheel: Equatable, Sendable {
        public var angle: Double
        public var amount: Double
        public init(angle: Double, amount: Double) { self.angle = angle; self.amount = amount }
    }

    /// 3D 表の 1 辺の画素数(17³ = 4913 点)。
    public static let dimension = 17

    /// チャンネル c(0 = 赤, 1 = 緑, 2 = 青)の効き(−1〜1)。
    static func tint(_ angleDeg: Double, channel c: Int) -> Double {
        cos(angleDeg * .pi / 180 - Double(c) * 2 * .pi / 3)
    }

    /// 1 点の変換(0〜1 の RGB → 0〜1 の RGB)。
    static func map(_ rgb: (Double, Double, Double), lift: Wheel, gamma: Wheel, gain: Wheel) -> (Double, Double, Double) {
        var out = [rgb.0, rgb.1, rgb.2]
        for c in 0..<3 {
            var v = out[c]
            let l = 0.25 * lift.amount * tint(lift.angle, channel: c)
            v = v + l * (1 - v)
            v *= 1 + 0.5 * gain.amount * tint(gain.angle, channel: c)
            v = min(max(v, 0), 1)
            let g = exp(0.5 * gamma.amount * tint(gamma.angle, channel: c))
            v = pow(v, 1 / g)
            out[c] = min(max(v, 0), 1)
        }
        return (out[0], out[1], out[2])
    }

    /// CIColorCube 用のデータ(Float の RGBA × dimension³、赤が一番速く動く並び)。
    public static func cubeData(lift: Wheel, gamma: Wheel, gain: Wheel) -> Data {
        let n = dimension
        var floats = [Float]()
        floats.reserveCapacity(n * n * n * 4)
        let step = 1 / Double(n - 1)
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let m = map((Double(r) * step, Double(g) * step, Double(b) * step), lift: lift, gamma: gamma, gain: gain)
                    floats.append(Float(m.0)); floats.append(Float(m.1)); floats.append(Float(m.2)); floats.append(1)
                }
            }
        }
        return floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
