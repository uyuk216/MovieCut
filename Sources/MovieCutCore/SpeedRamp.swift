import Foundation

/// スピードランプの 1 点: クリップの頭からの時刻 `t`(秒)と、その時刻の速度 `v`(0.25〜4)。
/// `ease` は「この点から次の点まで」の進み方(キーフレームの `Keyframe.ease` と同じ意味)。
/// 既定は直線で、そのときはファイルに書かない(古いファイルは ease 無し = 直線として読む)。
public struct SpeedKey: Codable, Equatable, Sendable {
    public var t: Double
    public var v: Double
    public var ease: Ease
    public init(t: Double, v: Double) { self.init(t: t, v: v, ease: .linear) }
    public init(t: Double, v: Double, ease: Ease) { self.t = t; self.v = v; self.ease = ease }

    enum CodingKeys: String, CodingKey { case t, v, ease }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        t = (try? c.decodeIfPresent(Double.self, forKey: .t)) ?? 0
        v = (try? c.decodeIfPresent(Double.self, forKey: .v)) ?? 1
        ease = (try? c.decodeIfPresent(Ease.self, forKey: .ease)) ?? .linear
        if !t.isFinite { t = 0 }
        if !v.isFinite { v = 1 }
    }

    /// ease が linear のときは書かない(従来のファイルと 1 バイトも変わらない)。
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(t, forKey: .t)
        try c.encode(v, forKey: .v)
        if ease != .linear { try c.encode(ease, forKey: .ease) }
    }
}

/// 速度ランプ(時間で速さが変わる)の純粋な計算。
///
/// 素材の時刻 = offset + ∫₀ᵗ speed(u) du。速度は区分ごとに、始点の `ease` で補間する(直線なら従来どおり台形の和で閉じた形。
/// 曲線のときは `Ease.integral` の解析的な積分を使う)。速度は常に正(0.25 以上)なので、積分は単調増加で、
/// 逆変換(素材の時刻 → クリップの時刻)は一意に決まる。
/// 点は時刻順・端は 0 と duration の両方を持つ(`sanitized` が整える)。
public enum SpeedRamp {
    /// 読んだ点を整える: 有限の値だけ・時刻を 0〜duration に収める・時刻順・同じ時刻は後の点を残す・速度を 0.25〜4 に収める・
    /// 両端(0 と duration)を持たせる(足りなければ端の速度を伸ばす)。整えた結果が空なら nil。`ease` はそのまま保つ。
    public static func sanitized(_ pts: [SpeedKey], duration: Double) -> [SpeedKey]? {
        guard duration > 0, duration.isFinite else { return nil }
        var ps = pts.filter { $0.t.isFinite && $0.v.isFinite }
            .map { SpeedKey(t: min(max($0.t, 0), duration), v: ClipTiming.clampSpeed($0.v), ease: $0.ease) }
        ps.sort { $0.t < $1.t }
        var out: [SpeedKey] = []
        for p in ps {
            if let last = out.last, abs(last.t - p.t) < 1e-9 { out[out.count - 1] = p } else { out.append(p) }
        }
        guard !out.isEmpty else { return nil }
        if out[0].t > 0 { out.insert(SpeedKey(t: 0, v: out[0].v, ease: out[0].ease), at: 0) } else { out[0].t = 0 }
        let last = out.count - 1
        if out[last].t < duration { out.append(SpeedKey(t: duration, v: out[last].v)) } else { out[last].t = duration }
        return out
    }

    /// 時刻 `t` の速度(始点の ease で補間。直線は従来の計算そのまま。範囲の外は端の値)。
    public static func speed(_ pts: [SpeedKey], at t: Double) -> Double {
        guard let f = pts.first, let l = pts.last else { return 1 }
        if t <= f.t { return f.v }
        if t >= l.t { return l.v }
        for i in 1..<pts.count where t <= pts[i].t {
            let a = pts[i - 1], b = pts[i]
            let dt = b.t - a.t
            guard dt > 0 else { return b.v }
            if a.ease == .linear { return a.v + (b.v - a.v) * (t - a.t) / dt }
            // 行き過ぎる曲線(バウンス風など)でも速度は 0.25〜4 に収める(積分が単調という前提を守るため)
            return ClipTiming.clampSpeed(a.v + (b.v - a.v) * a.ease.apply((t - a.t) / dt))
        }
        return l.v
    }

    /// 頭から時刻 `t` までに使う素材の長さ(秒)= ∫₀ᵗ speed。最後の点より後は最後の速度を保つ。t ≤ 0 は 0。
    /// 直線の区間は従来の台形の計算とまったく同じ式を使う(既存プロジェクトの値が変わらない)。
    public static func integral(_ pts: [SpeedKey], upTo t: Double) -> Double {
        guard let last = pts.last, t > 0 else { return 0 }
        var total = 0.0
        for i in 1..<max(1, pts.count) {
            let a = pts[i - 1], b = pts[i]
            if t <= a.t { break }
            let end = min(t, b.t)
            let dt = b.t - a.t
            let vEnd = dt > 0 ? a.v + (b.v - a.v) * (end - a.t) / dt : b.v
            if a.ease == .linear || dt <= 0 {
                total += (end - a.t) * (a.v + vEnd) / 2
            } else if a.ease == .hold {
                total += (end - a.t) * a.v   // 階段: 次の点まで始点の速度のまま
            } else if overshoots(a.ease) {
                total += clampedIntegral(a, b, upTo: end)
            } else {
                let u = (end - a.t) / dt
                total += dt * (a.v * u + (b.v - a.v) * a.ease.integral(u))
            }
        }
        if t > last.t { total += (t - last.t) * last.v }
        return total
    }

    /// 曲線の進み具合が 0〜1 の外へはみ出すか(バウンス風など)。制御点が範囲内なら曲線も範囲内。
    /// はみ出す区間では解析的な積分が「丸めた速度」の積分と合わないので、数値積分に切り替える。
    static func overshoots(_ ease: Ease) -> Bool {
        guard case .bezier(_, let y1, _, let y2) = ease else { return false }
        guard y1 < 0 || y1 > 1 || y2 < 0 || y2 > 1 else { return false }
        for i in 0...20 {
            let v = ease.apply(Double(i) / 20)
            if v < -1e-9 || v > 1 + 1e-9 { return true }
        }
        return false
    }

    /// 区間 [a.t, end] の、範囲に丸めた速度の積分(台形・細分)。行き過ぎる曲線のときだけ使う。
    /// 分割は区間の頭から固定幅にする(end を伸ばしても過去の分の近似が変わらず、積分が単調になる)。
    static func clampedIntegral(_ a: SpeedKey, _ b: SpeedKey, upTo end: Double) -> Double {
        let span = end - a.t
        let dt = b.t - a.t
        guard span > 0, dt > 0 else { return 0 }
        let w = dt / 400
        func v(_ t: Double) -> Double { ClipTiming.clampSpeed(a.v + (b.v - a.v) * a.ease.apply((t - a.t) / dt)) }
        var sum = 0.0
        var t0 = a.t
        var prev = v(a.t)
        while t0 + w <= end {
            let cur = v(t0 + w)
            sum += (prev + cur) / 2 * w
            prev = cur
            t0 += w
        }
        if end > t0 {
            sum += (prev + v(end)) / 2 * (end - t0)
        }
        return sum
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
    /// 境目を含む区間の ease は右の先頭の点が引き継ぐ(キーフレームの分割と同じ扱い: 曲線のときは、分けた後の区間の中で
    /// 曲線が引き直されるので、境目の速度だけが一致する)。
    public static func split(_ pts: [SpeedKey], at cut: Double) -> (left: [SpeedKey], right: [SpeedKey]) {
        let vCut = speed(pts, at: cut)
        let easeAtCut = pts.last(where: { $0.t <= cut + 1e-9 })?.ease ?? .linear
        var left = pts.filter { $0.t < cut - 1e-9 }
        left.append(SpeedKey(t: cut, v: vCut))
        var right = [SpeedKey(t: 0, v: vCut, ease: easeAtCut)]
        right += pts.filter { $0.t > cut + 1e-9 }.map { SpeedKey(t: $0.t - cut, v: $0.v, ease: $0.ease) }
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
        return [SpeedKey(t: 0, v: first.v, ease: first.ease)] + pts.map { SpeedKey(t: $0.t + n, v: $0.v, ease: $0.ease) }
    }
}
