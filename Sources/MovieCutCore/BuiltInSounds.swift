import Foundation

// MARK: - 同梱の効果音(コードで合成。第三者の素材は使わない)
//
// どの音も、固定の式と固定の乱数の種だけで作る(同じ入力なら毎回まったく同じサンプル)。
// 44.1 kHz・モノラル・16 ビットの WAV にして、アプリのデータフォルダへ書き出す(`BuiltInLibrary`)。

public enum BuiltInSounds {
    public static let sampleRate = 44100
    /// 最大の振幅(0〜1)。書き出す前に、ピークをこの値へそろえる(クリップしない余裕)。
    public static let peakLevel: Float = 0.8

    public struct Spec: Equatable, Sendable {
        public let id: String
        /// 一覧に出すファイル名(拡張子なし)。日本語。
        public let title: String
        public let duration: Double
    }

    /// 12 種。並びは一覧の並び(名前順に並べ替えても同じ件数)。
    public static let specs: [Spec] = [
        Spec(id: "click", title: "効果音-クリック", duration: 0.08),
        Spec(id: "tick", title: "効果音-カチッ", duration: 0.12),
        Spec(id: "pop", title: "効果音-ポップ", duration: 0.15),
        Spec(id: "boing", title: "効果音-ぼよん", duration: 0.4),
        Spec(id: "whooshShort", title: "効果音-シュッ", duration: 0.5),
        Spec(id: "whooshLong", title: "効果音-ヒュー", duration: 1.2),
        Spec(id: "chime", title: "効果音-チャイム", duration: 1.5),
        Spec(id: "bell", title: "効果音-ベル", duration: 2.0),
        Spec(id: "riser", title: "効果音-ライザー", duration: 3.0),
        Spec(id: "impact", title: "効果音-ドン", duration: 0.8),
        Spec(id: "ping", title: "効果音-ピコン", duration: 0.35),
        Spec(id: "success", title: "効果音-できた", duration: 0.9),
    ]

    /// 固定の種の乱数(xorshift64*)。-1〜1。
    static func noise(count: Int, seed: UInt64) -> [Double] {
        var s = seed == 0 ? 0x9E3779B97F4A7C15 : seed
        return (0..<count).map { _ in
            s ^= s >> 12; s ^= s << 25; s ^= s >> 27
            let v = s &* 2685821657736338717
            return Double(v >> 11) / Double(1 << 53) * 2 - 1
        }
    }

    /// 1 つの音のサンプル(-1〜1、ピークを `peakLevel` にそろえ、終わりは 5 ms でゼロへ落とす)。未知の id は空。
    public static func render(_ id: String) -> [Float] {
        guard let spec = specs.first(where: { $0.id == id }) else { return [] }
        let n = Int((spec.duration * Double(sampleRate)).rounded())
        let sr = Double(sampleRate)
        let nz = noise(count: n, seed: UInt64(truncatingIfNeeded: id.utf8.reduce(1469598103934665603 as UInt64) { ($0 ^ UInt64($1)) &* 1099511628211 }))
        let twoPi = 2 * Double.pi
        var out = [Double](repeating: 0, count: n)

        /// 状態変数フィルタ(帯域)。fc は時々刻々変えられる。
        func sweptBand(_ fc: (Double) -> Double, q: Double) {
            var low = 0.0, band = 0.0
            for i in 0..<n {
                let t = Double(i) / sr
                let f = 2 * sin(Double.pi * min(fc(t), sr / 6) / sr)
                low += f * band
                let high = nz[i] - low - q * band
                band += f * high
                let env = pow(sin(Double.pi * t / spec.duration), 2)
                out[i] = band * env
            }
        }

        switch id {
        case "click":
            var prev = 0.0
            for i in 0..<n {
                let t = Double(i) / sr
                let hp = nz[i] - prev; prev = nz[i]
                out[i] = hp * exp(-t * 90) + 0.5 * sin(twoPi * 2400 * t) * exp(-t * 120)
            }
        case "tick":
            for i in 0..<n {
                let t = Double(i) / sr
                var v = sin(twoPi * 1800 * t) * exp(-t * 60)
                if t >= 0.05 { v += 0.8 * sin(twoPi * 1200 * (t - 0.05)) * exp(-(t - 0.05) * 80) }
                out[i] = v
            }
        case "pop":
            var phase = 0.0
            for i in 0..<n {
                let t = Double(i) / sr
                phase += twoPi * (900 * exp(-t * 18) + 150) / sr
                out[i] = sin(phase) * exp(-t * 20) * (1 - exp(-t * 800))
            }
        case "boing":
            var phase = 0.0
            for i in 0..<n {
                let t = Double(i) / sr
                let f = 220 * (1 + 1.5 * exp(-t * 8) * cos(twoPi * 9 * t))
                phase += twoPi * f / sr
                out[i] = sin(phase) * exp(-t * 7) * (1 - exp(-t * 600))
            }
        case "whooshShort":
            sweptBand({ 400 + 2600 * sin(Double.pi * $0 / 0.5) }, q: 0.35)
        case "whooshLong":
            sweptBand({ 300 + 1800 * pow(sin(Double.pi * $0 / 1.2), 2) }, q: 0.3)
        case "chime":
            for i in 0..<n {
                let t = Double(i) / sr
                var v = 0.0
                for (k, f) in [880.0, 1320, 1760, 2640].enumerated() { v += sin(twoPi * f * t) * exp(-t * (3 + Double(k) * 1.5)) / Double(k + 1) }
                out[i] = v * (1 - exp(-t * 500))
            }
        case "bell":
            let parts: [(Double, Double)] = [(1, 1), (2.76, 0.6), (5.40, 0.35), (8.93, 0.2)]
            for i in 0..<n {
                let t = Double(i) / sr
                var v = 0.0
                for (r, a) in parts { v += a * sin(twoPi * 520 * r * t) * exp(-t * (2.2 + r * 0.4)) }
                out[i] = v * (1 - exp(-t * 800))
            }
        case "riser":
            var phase = 0.0
            for i in 0..<n {
                let t = Double(i) / sr
                let u = t / spec.duration
                phase += twoPi * (200 * pow(10, u)) / sr
                let tone = sin(phase) * 0.6 + 0.25 * sin(phase * 2.01)
                out[i] = (tone + 0.35 * nz[i] * u) * pow(u, 1.5)
            }
        case "impact":
            var low = 0.0, phase = 0.0
            for i in 0..<n {
                let t = Double(i) / sr
                phase += twoPi * (40 + 80 * exp(-t * 14)) / sr
                low += 0.08 * (nz[i] - low)
                out[i] = (sin(phase) + 0.8 * low) * exp(-t * 5) * (1 - exp(-t * 900))
            }
        case "ping":
            for i in 0..<n {
                let t = Double(i) / sr
                let v = t < 0.12 ? sin(twoPi * 880 * t) * exp(-t * 14) : sin(twoPi * 1320 * (t - 0.12)) * exp(-(t - 0.12) * 12)
                out[i] = v * (1 - exp(-t * 800))
            }
        case "success":
            for (k, f) in [523.25, 659.25, 783.99, 1046.5].enumerated() {
                let s = Double(k) * 0.12
                for i in 0..<n {
                    let t = Double(i) / sr - s
                    guard t >= 0 else { continue }
                    out[i] += sin(twoPi * f * t) * exp(-t * 6) * (1 - exp(-t * 800))
                }
            }
        default: break
        }

        // 終わりを 5 ms でゼロへ(ぷつっと切れない)。ピークをそろえる
        let fade = max(1, Int(0.005 * sr))
        for k in 0..<min(fade, n) { out[n - 1 - k] *= Double(k) / Double(fade) }
        let peak = out.map { abs($0) }.max() ?? 0
        guard peak > 1e-9 else { return [Float](repeating: 0, count: n) }
        let g = Double(peakLevel) / peak
        return out.map { Float($0 * g) }
    }

    /// 16 ビット PCM・モノラルの WAV のバイト列。
    public static func wavData(_ samples: [Float], sampleRate: Int = sampleRate) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        let bytes = samples.count * 2
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + bytes))
        d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(bytes))
        for s in samples { u16(UInt16(bitPattern: Int16((max(-1, min(1, s)) * 32767).rounded()))) }
        return d
    }
}
