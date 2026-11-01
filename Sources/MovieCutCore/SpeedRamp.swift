import Foundation

/// スピードランプの 1 点: クリップの頭からの時刻 `t`(秒)と、その時刻の速度 `v`(0.25〜4)。点と点のあいだは速度を直線でつなぐ。
public struct SpeedKey: Codable, Equatable, Sendable {
    public var t: Double
    public var v: Double
    public init(t: Double, v: Double) { self.t = t; self.v = v }
}

/// 速度ランプ(時間で速さが変わる)の純粋な計算。
///
/// 素材の時刻 = offset + ∫₀ᵗ speed(u) du。速度は区分ごとに直線なので、積分は区分ごとの台形の和で閉じた形になる。
/// 速度は常に正(0.25 以上)なので、積分は単調増加で、逆変換(素材の時刻 → クリップの時刻)は一意に決まる。
/// 点は時刻順・端は 0 と duration の両方を持つ(`sanitized` が整える)。
public enum SpeedRamp {
    /// 読んだ点を整える: 有限の値だけ・時刻を 0〜duration に収める・時刻順・同じ時刻は後の点を残す・速度を 0.25〜4 に収める・
    /// 両端(0 と duration)を持たせる(足りなければ端の速度を伸ばす)。整えた結果が空なら nil。
    public static func sanitized(_ pts: [SpeedKey], duration: Double) -> [SpeedKey]? {
        guard duration > 0, duration.isFinite else { return nil }
        var ps = pts.filter { $0.t.isFinite && $0.v.isFinite }
            .map { SpeedKey(t: min(max($0.t, 0), duration), v: ClipTiming.clampSpeed($0.v)) }
        ps.sort { $0.t < $1.t }
        var out: [SpeedKey] = []
        for p in ps {
            if let last = out.last, abs(last.t - p.t) < 1e-9 { out[out.count - 1] = p } else { out.append(p) }
        }
        guard !out.isEmpty else { return nil }
        if out[0].t > 0 { out.insert(SpeedKey(t: 0, v: out[0].v), at: 0) } else { out[0].t = 0 }
        let last = out.count - 1
        if out[last].t < duration { out.append(SpeedKey(t: duration, v: out[last].v)) } else { out[last].t = duration }
        return out
    }

    /// 時刻 `t` の速度(直線補間。範囲の外は端の値)。
    public static func speed(_ pts: [SpeedKey], at t: Double) -> Double {
        guard let f = pts.first, let l = pts.last else { return 1 }
        if t <= f.t { return f.v }
        if t >= l.t { return l.v }
        for i in 1..<pts.count where t <= pts[i].t {
            let a = pts[i - 1], b = pts[i]
            let dt = b.t - a.t
            return dt > 0 ? a.v + (b.v - a.v) * (t - a.t) / dt : b.v
        }
        return l.v
    }

    /// 頭から時刻 `t` までに使う素材の長さ(秒)= ∫₀ᵗ speed。最後の点より後は最後の速度を保つ。t ≤ 0 は 0。
    public static func integral(_ pts: [SpeedKey], upTo t: Double) -> Double {
        guard let last = pts.last, t > 0 else { return 0 }
        var total = 0.0
        for i in 1..<max(1, pts.count) {
            let a = pts[i - 1], b = pts[i]
            if t <= a.t { break }
            let end = min(t, b.t)
            let dt = b.t - a.t
            let vEnd = dt > 0 ? a.v + (b.v - a.v) * (end - a.t) / dt : b.v
            total += (end - a.t) * (a.v + vEnd) / 2
        }
        if t > last.t { total += (t - last.t) * last.v }
        return total
    }

    /// 素材の長さ `s`(秒)に達するクリップの時刻(`integral` の逆)。単調なので二分法で求める。s ≤ 0 は 0。
    public static func time(_ pts: [SpeedKey], forIntegral s: Double) -> Double {
        guard let last = pts.last, s > 0 else { return 0 }
        let total = integral(pts, upTo: last.t)
        if s >= total { return last.t + (s - total) / last.v }
        var lo = 0.0, hi = last.t
        for _ in 0..<80 {
            let mid = (lo + hi) / 2
            if integral(pts, upTo: mid) < s { lo = mid } else { hi = mid }
        }
        return (lo + hi) / 2
    }

    /// 時刻 `cut` で二つに分ける。左は [0, cut]、右は [cut, D] を頭から 0 に詰めた列(どちらも両端の点を持つ。境目の速度は同じ)。
    public static func split(_ pts: [SpeedKey], at cut: Double) -> (left: [SpeedKey], right: [SpeedKey]) {
        let vCut = speed(pts, at: cut)
        var left = pts.filter { $0.t < cut - 1e-9 }
        left.append(SpeedKey(t: cut, v: vCut))
        var right = [SpeedKey(t: 0, v: vCut)]
        right += pts.filter { $0.t > cut + 1e-9 }.map { SpeedKey(t: $0.t - cut, v: $0.v) }
        return (left, right)
    }

    /// 長さを `d` にそろえる。短くするときは切り、長くするときは最後の速度を保って伸ばす。
    public static func fit(_ pts: [SpeedKey], to d: Double) -> [SpeedKey] {
        guard let last = pts.last else { return pts }
        if abs(d - last.t) < 1e-9 { return pts }
        if d < last.t { return split(pts, at: d).left }
        return pts + [SpeedKey(t: d, v: last.v)]
    }

    /// 頭の前に `n` 秒ぶん(最初の速度のまま)足す。点は n だけ後ろへずれる。
    public static func extendedHead(_ pts: [SpeedKey], by n: Double) -> [SpeedKey] {
        guard let first = pts.first, n > 0 else { return pts }
        return [SpeedKey(t: 0, v: first.v)] + pts.map { SpeedKey(t: $0.t + n, v: $0.v) }
    }
}
