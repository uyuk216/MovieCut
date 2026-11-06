import Foundation

// MARK: - イージング

/// キーフレームの「次のキーまでの動き方」。ファイルでは文字列("linear" / "easeIn" / "easeOut" / "easeInOut" / "hold" /
/// "bezier:0.25,0.1,0.25,1")で書く。読めない文字列は linear とみなす。
public enum Ease: Equatable, Hashable, Sendable, Codable {
    case linear, easeIn, easeOut, easeInOut
    /// 階段(次のキーに来るまで値を変えない)。
    case hold
    /// CSS の cubic-bezier と同じ(始点 (0,0)・終点 (1,1)、制御点 (c1x,c1y) (c2x,c2y))。c1x・c2x は 0〜1。
    case bezier(Double, Double, Double, Double)

    /// ファイルに書く文字列。
    public var token: String {
        switch self {
        case .linear: return "linear"
        case .easeIn: return "easeIn"
        case .easeOut: return "easeOut"
        case .easeInOut: return "easeInOut"
        case .hold: return "hold"
        case .bezier(let a, let b, let c, let d): return "bezier:\(Self.num(a)),\(Self.num(b)),\(Self.num(c)),\(Self.num(d))"
        }
    }

    /// 数を短く(1.0 → 1)。往復で値が変わらない最短の表記。
    private static func num(_ v: Double) -> String {
        v == v.rounded() && abs(v) < 1e9 ? String(Int(v)) : "\(v)"
    }

    /// 文字列から。読めなければ nil。
    public init?(token: String) {
        switch token {
        case "linear": self = .linear
        case "easeIn": self = .easeIn
        case "easeOut": self = .easeOut
        case "easeInOut": self = .easeInOut
        case "hold": self = .hold
        default:
            guard token.hasPrefix("bezier:") else { return nil }
            let nums = token.dropFirst("bezier:".count).split(separator: ",", omittingEmptySubsequences: false).map { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard nums.count == 4, let a = nums[0], let b = nums[1], let c = nums[2], let d = nums[3],
                  [a, b, c, d].allSatisfy(\.isFinite) else { return nil }
            self = .bezier(min(max(a, 0), 1), b, min(max(c, 0), 1), d)
        }
    }

    public init(from decoder: Decoder) throws {
        let s = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self = Ease(token: s) ?? .linear
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(token)
    }

    /// 進み具合 u(0〜1)を、動きの進み具合に直す。端(0 / 1)は必ず 0 / 1。hold は 1 になるまで 0。
    public func apply(_ u: Double) -> Double {
        if !(u > 0) { return 0 }
        if u >= 1 { return 1 }
        switch self {
        case .linear: return u
        case .hold: return 0
        case .easeIn: return Ease.cubicBezier(0.42, 0, 1, 1, u)
        case .easeOut: return Ease.cubicBezier(0, 0, 0.58, 1, u)
        case .easeInOut: return Ease.cubicBezier(0.42, 0, 0.58, 1, u)
        case .bezier(let a, let b, let c, let d): return Ease.cubicBezier(a, b, c, d, u)
        }
    }

    /// CSS の cubic-bezier(x1, y1, x2, y2): x = u になる媒介変数を解いて、そのときの y を返す。
    /// ニュートン法(傾きが小さすぎるときは二分法)で 1e-7 以内まで解く。
    public static func cubicBezier(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ x: Double) -> Double {
        if !(x > 0) { return 0 }
        if x >= 1 { return 1 }
        // B(s) = 3(1-s)^2 s p1 + 3(1-s) s^2 p2 + s^3
        func bez(_ p1: Double, _ p2: Double, _ s: Double) -> Double {
            let m = 1 - s
            return 3 * m * m * s * p1 + 3 * m * s * s * p2 + s * s * s
        }
        func slope(_ p1: Double, _ p2: Double, _ s: Double) -> Double {
            let m = 1 - s
            return 3 * m * m * p1 + 6 * m * s * (p2 - p1) + 3 * s * s * (1 - p2)
        }
        var s = x
        for _ in 0..<8 {
            let err = bez(x1, x2, s) - x
            if abs(err) < 1e-9 { return bez(y1, y2, s) }
            let d = slope(x1, x2, s)
            if abs(d) < 1e-6 { break }
            s -= err / d
            if s < 0 || s > 1 { break }
        }
        var lo = 0.0, hi = 1.0
        s = x
        for _ in 0..<60 {
            let v = bez(x1, x2, s)
            if abs(v - x) < 1e-9 { break }
            if v < x { lo = s } else { hi = s }
            s = (lo + hi) / 2
        }
        return bez(y1, y2, s)
    }

    /// インスペクタの選択肢(曲線の指定は bezier を直接ファイルに書く)。
    public static let presets: [(label: String, ease: Ease)] = [
        ("一定", .linear), ("ゆっくり始まる", .easeIn), ("ゆっくり終わる", .easeOut), ("ゆっくり始まって終わる", .easeInOut), ("階段（止める）", .hold),
    ]
}

// MARK: - キーフレーム

/// 1 つのキー。`t` はクリップの頭からの秒(クリップを動かしてもそのまま)、`v` は値。
/// `ease` は「このキーから次のキーまで」の動き方。
public struct Keyframe: Equatable, Codable, Sendable {
    public var t: Double
    public var v: Double
    public var ease: Ease

    public init(t: Double, v: Double, ease: Ease = .linear) {
        self.t = t; self.v = v; self.ease = ease
    }

    enum CodingKeys: String, CodingKey { case t, v, ease }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        t = (try? c.decodeIfPresent(Double.self, forKey: .t)) ?? 0
        v = (try? c.decodeIfPresent(Double.self, forKey: .v)) ?? 0
        ease = (try? c.decodeIfPresent(Ease.self, forKey: .ease)) ?? .linear
        if !t.isFinite { t = 0 }
        if !v.isFinite { v = 0 }
    }

    /// ease が linear のときは書かない。
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(t, forKey: .t)
        try c.encode(v, forKey: .v)
        if ease != .linear { try c.encode(ease, forKey: .ease) }
    }
}

// MARK: - 評価

/// アニメーションできる項目の名前と、値の評価(UI にも Undo にも依存しない純粋な関数)。
public enum Animation {
    /// 画像・動画・文字のクリップで動かせる項目。
    public static let transformKeys = ["x", "y", "scale", "rotation", "opacity"]
    /// ぼかし範囲のクリップで動かせる項目。
    public static let blurRegionKeys = ["x", "y", "w", "h", "strength"]
    /// 音量(音声・ボイス・動画)。値は倍率(1 = 等倍、0〜2)。
    public static let volumeKey = "volume"

    /// そのクリップの種類で動かせる項目(クリップごとのぼかし "blur" を持つ画像・動画・文字は blur も)。
    public static func keys(for clip: Clip) -> [String] {
        switch clip.type {
        case .blur: return blurRegionKeys
        case .visualizer: return ["x", "y", "w", "h"]
        case .shape: return ["x", "y", "w", "h", "rotation", "opacity"]
        case .adjustment: return ["opacity"] + clip.effectKeys
        case .video: return transformKeys + ["blur"] + clip.effectKeys + [volumeKey]
        case .image, .text, .compound, .tachie: return transformKeys + ["blur"] + clip.effectKeys
        case .audio, .voice: return clip.isFreeze ? [] : [volumeKey]
        default: return []
        }
    }

    /// キー列を時刻順にし、同じ時刻(1e-9 以内)は後のものを残す。
    public static func normalized(_ keys: [Keyframe]) -> [Keyframe] {
        var sorted = keys.filter { $0.t.isFinite && $0.v.isFinite }
        // 安定ソート(同じ時刻は元の並びのまま)
        sorted = sorted.enumerated().sorted { a, b in a.element.t != b.element.t ? a.element.t < b.element.t : a.offset < b.offset }.map(\.element)
        var out: [Keyframe] = []
        for k in sorted {
            if let l = out.last, abs(l.t - k.t) < 1e-9 { out[out.count - 1] = k } else { out.append(k) }
        }
        return out
    }

    /// キー列の `t`(クリップの頭からの秒)での値。キーが無ければ nil。最初より前・最後より後は端の値のまま。
    public static func interpolate(_ keys: [Keyframe], at t: Double) -> Double? {
        guard !keys.isEmpty else { return nil }
        // ほとんどは整列済み・重複なしなので、確かめて速い道を通る
        var ks = keys
        var ordered = true
        for i in 1..<max(1, ks.count) where !(ks[i - 1].t < ks[i].t) { ordered = false; break }
        if !ordered { ks = normalized(keys) }
        guard let first = ks.first, let last = ks.last else { return nil }
        if ks.count == 1 || t <= first.t { return first.v }
        if t >= last.t { return last.v }
        // t を挟む 2 つのキー
        var i = 0
        while i + 1 < ks.count - 1 && ks[i + 1].t <= t { i += 1 }
        let a = ks[i], b = ks[i + 1]
        let span = b.t - a.t
        guard span > 0 else { return b.v }
        let k = a.ease.apply((t - a.t) / span)
        return a.v + (b.v - a.v) * k
    }

    /// クリップの `key` の、クリップ内の時刻 `t`(頭からの秒)での値。キーが無い項目は、いまの設定値(未設定は既定値)。
    public static func value(of key: String, in clip: Clip, at t: Double) -> Double {
        if !clip.keyframes.isEmpty, let ks = clip.keyframes[key], let v = interpolate(ks, at: t) { return v }
        return clip.staticValue(of: key)
    }

    /// その項目にキーがあるか。
    public static func isAnimated(_ key: String, in clip: Clip) -> Bool {
        guard !clip.keyframes.isEmpty else { return false }
        return !(clip.keyframes[key]?.isEmpty ?? true)
    }

    /// 項目ごとの値の範囲(キーの値・直接操作で使う。x, y は画面の外へ出す動きのため広い)。
    public static func range(of key: String, type: ClipType) -> ClosedRange<Double> {
        switch key {
        case "x", "y": return type == .blur ? 0...1 : -2...3
        case "w", "h": return 0...1
        case "scale": return 0.05...20
        case "rotation": return -3600...3600
        case "opacity": return 0...1
        case "blur", "strength": return 0...300
        case "volume": return 0...2
        default: return -1e9...1e9
        }
    }

    /// クリップ込みの範囲(エフェクトの引数は、そのエフェクトの仕様の範囲)。
    public static func clamp(_ key: String, _ v: Double, in clip: Clip) -> Double {
        if let s = EffectKey.spec(key, in: clip) { return s.clamp(v) }
        return clamp(key, v, type: clip.type)
    }

    public static func clamp(_ key: String, _ v: Double, type: ClipType) -> Double {
        let r = range(of: key, type: type)
        guard v.isFinite else { return r.lowerBound }
        return min(max(v, r.lowerBound), r.upperBound)
    }

    /// クリップ込みの名前(エフェクトの引数は「エフェクト名 引数名」)。
    public static func label(of key: String, in clip: Clip) -> String {
        if let (i, p) = EffectKey.parse(key), clip.effects.indices.contains(i), let k = clip.effects[i].known, let s = k.spec(p) {
            return k.params.count > 1 ? "\(k.label) \(s.label)" : k.label
        }
        return label(of: key)
    }

    /// 画面に出す名前。
    public static func label(of key: String) -> String {
        switch key {
        case "x": return "横位置"
        case "y": return "縦位置"
        case "scale": return "拡大"
        case "rotation": return "回転"
        case "opacity": return "不透明度"
        case "blur": return "ぼかし"
        case "w": return "幅"
        case "h": return "高さ"
        case "strength": return "ぼかしの強さ"
        case "volume": return "音量"
        default: return key
        }
    }

    // MARK: 編集に追従する

    /// 全部のキーの時刻をずらす(左端のトリム: 頭が d 進んだら −d)。
    public static func shifted(_ ks: [String: [Keyframe]], by d: Double) -> [String: [Keyframe]] {
        guard !ks.isEmpty, d != 0 else { return ks }
        return ks.mapValues { $0.map { Keyframe(t: $0.t + d, v: $0.v, ease: $0.ease) } }
    }

    /// 分割。`cut` はクリップの頭からの秒。両側とも、切れ目で値が途切れないよう境目のキーを足す。
    /// 右は時刻を −cut ずらす。境目のキーのイージングは、元の区間のものを引き継ぐ(直線・階段なら形も同じ。
    /// 曲線のときは、分けた後の区間の中で曲線が引き直されるので、境目の値だけが一致する)。
    public static func split(_ ks: [String: [Keyframe]], at cut: Double) -> (left: [String: [Keyframe]], right: [String: [Keyframe]]) {
        let eps = 1e-9
        var left: [String: [Keyframe]] = [:], right: [String: [Keyframe]] = [:]
        for (key, raw) in ks {
            let list = normalized(raw)
            guard !list.isEmpty, let vCut = interpolate(list, at: cut) else { continue }
            // 左: cut までのキー + (後ろにキーがあるなら)境目
            var l = list.filter { $0.t <= cut + eps }
            if list.contains(where: { $0.t > cut + eps }), !(l.last.map { abs($0.t - cut) < eps } ?? false) {
                l.append(Keyframe(t: cut, v: vCut))
            }
            // 右: cut 以降のキー(−cut ずらす) + 先頭に境目
            var r = list.filter { $0.t >= cut - eps }.map { Keyframe(t: $0.t - cut, v: $0.v, ease: $0.ease) }
            if !(r.first.map { abs($0.t) < eps } ?? false) {
                // 境目を含む区間のイージング(その前のキーのもの)
                let ease = list.last(where: { $0.t < cut - eps })?.ease ?? .linear
                r.insert(Keyframe(t: 0, v: vCut, ease: ease), at: 0)
            }
            left[key] = l
            right[key] = r
        }
        return (left, right)
    }

    /// 全項目のキーの時刻(重複なし・昇順)。
    public static func allKeyTimes(_ ks: [String: [Keyframe]], tolerance: Double = 1e-6) -> [Double] {
        var ts: [Double] = []
        for l in ks.values { for k in l { ts.append(k.t) } }
        ts.sort()
        var out: [Double] = []
        for t in ts { if let last = out.last, t - last <= tolerance { continue }; out.append(t) }
        return out
    }
}
