import Foundation

// MARK: - BGM の自動ダッキング(声があるときに BGM を下げる)

/// 音声クリップ(BGM)ごとの設定。`duck` が無ければ何もしない。ファイルには設定したときだけ書く。
/// 声 = 音の出るボイスクリップ(`.voice`)の鳴っている区間。声の頭の `attack` 秒前から下げ始め(先読み)、
/// 声の頭までに `amount` dB 下がりきる。声が終わったら `release` 秒かけて元の音量へ戻る(dB 直線のなめらかな変化)。
/// 時刻だけで決まる(状態を持たない)ので、再生用ミックスも書き出しも同じ計算になり、10 秒の塊の境目でも途切れない。
public struct Duck: Codable, Equatable, Sendable {
    public static let amountRange: ClosedRange<Double> = -40 ... -1
    public static let attackRange: ClosedRange<Double> = 0.01 ... 2
    public static let releaseRange: ClosedRange<Double> = 0.05 ... 5
    public static let defaultAmount = -12.0, defaultAttack = 0.15, defaultRelease = 0.5

    /// false のときだけ書く(設定値は残したまま一時的に切る)。
    public var enabled: Bool = true
    /// 下げる量(dB、負の値)
    public var amount: Double?
    public var attack: Double?
    public var release: Double?
    public var extra: [String: JSONValue] = [:]
    static let knownKeys: Set<String> = ["enabled", "amount", "attack", "release"]

    public init(amount: Double? = nil, attack: Double? = nil, release: Double? = nil, enabled: Bool = true) {
        self.amount = amount; self.attack = attack; self.release = release; self.enabled = enabled
    }

    private static func clamp(_ v: Double?, _ r: ClosedRange<Double>, _ d: Double) -> Double {
        guard let v, v.isFinite else { return d }
        return min(max(v, r.lowerBound), r.upperBound)
    }
    public var amountDb: Double { Self.clamp(amount, Self.amountRange, Self.defaultAmount) }
    public var attackSeconds: Double { Self.clamp(attack, Self.attackRange, Self.defaultAttack) }
    public var releaseSeconds: Double { Self.clamp(release, Self.releaseRange, Self.defaultRelease) }
    public var isActive: Bool { enabled }
    /// 設定値が何も入っていない(切ったときに `duck` ごと外してよい)。
    var hasNoSettings: Bool { amount == nil && attack == nil && release == nil && extra.isEmpty }

    /// 音に効く項目だけから作る文字列(再生用ミックスの鍵に足す)。
    public var cacheToken: String { "\(amountDb),\(attackSeconds),\(releaseSeconds)" }

    public init(from decoder: Decoder) throws {
        let l = Lenient(c: try decoder.container(keyedBy: AnyKey.self), known: Self.knownKeys)
        enabled = l.bool("enabled") ?? true
        amount = l.double("amount"); attack = l.double("attack"); release = l.double("release")
        extra = l.extra()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        for (k, v) in extra { try c.encode(v, forKey: AnyKey(k)) }
        if !enabled { try c.encode(false, forKey: AnyKey("enabled")) }
        try c.encodeIfPresent(amount, forKey: AnyKey("amount"))
        try c.encodeIfPresent(attack, forKey: AnyKey("attack"))
        try c.encodeIfPresent(release, forKey: AnyKey("release"))
    }
}

public extension Clip {
    var hasDuck: Bool { duck?.isActive ?? false }
    /// ダッキングを設定できるクリップ(BGM などの音声クリップ。フリーズは無音)。
    static func supportsDuck(_ c: Clip) -> Bool { c.type == .audio && !c.isFreeze }
}

// MARK: - 包絡線の計算

public enum Ducking {
    /// 声の区間(秒)。
    public struct Span: Equatable, Sendable {
        public var start: Double
        public var end: Double
        public init(start: Double, end: Double) { self.start = start; self.end = end }
    }

    /// 声として扱うクリップ: 音の出る(src があり、長さがあり、音量が 0 でない)ボイスクリップ。消音・ソロで鳴らないレイヤーは除く。
    public static func voiceSpans(in project: Project) -> [Span] {
        var spans: [Span] = []
        for tr in project.tracks where project.isAudible(tr) {
            for c in tr.clips where c.type == .voice {
                guard let s = c.src, !s.isEmpty, c.duration > 0, c.volumeOrDefault > 0 else { continue }
                spans.append(Span(start: c.start, end: c.start + c.duration))
            }
        }
        return merged(spans)
    }

    /// 開始順に並べ、重なる・接する区間を 1 つにする。
    public static func merged(_ spans: [Span]) -> [Span] {
        var out: [Span] = []
        for s in spans.sorted(by: { $0.start < $1.start }) where s.end > s.start {
            if let last = out.last, s.start <= last.end { out[out.count - 1].end = max(last.end, s.end) }
            else { out.append(s) }
        }
        return out
    }

    /// 時刻 t での「下がり具合」0〜1(0 = 下げない、1 = 全部下げる)。複数の声は大きい方を取る。
    public static func depth(at t: Double, spans: [Span], attack: Double, release: Double) -> Double {
        var d = 0.0
        for s in spans {
            let v: Double
            if t >= s.start && t <= s.end { v = 1 }
            else if t < s.start { v = t > s.start - attack ? (t - (s.start - attack)) / attack : 0 }
            else { v = t < s.end + release ? 1 - (t - s.end) / release : 0 }
            if v > d { d = v }
        }
        return d
    }

    /// 倍率(リニア)。depth 0 = 1、depth 1 = 10^(amountDb/20)。
    public static func gain(depth: Double, amountDb: Double) -> Float {
        depth <= 0 ? 1 : Float(pow(10, amountDb * depth / 20))
    }

    /// [startFrame, startFrame + count) の各サンプルの倍率(サンプルレート sr)。声が無ければ全部 1。
    public static func gains(startFrame: Int, count: Int, sr: Double, spans: [Span], duck: Duck) -> [Float] {
        var out = [Float](repeating: 1, count: max(0, count))
        guard count > 0, !spans.isEmpty else { return out }
        let a = duck.attackSeconds, r = duck.releaseSeconds, db = duck.amountDb
        let t0 = Double(startFrame) / sr, t1 = Double(startFrame + count) / sr
        // この塊に届く声だけを見る(声の数が多くても塊ごとの計算は軽い)
        let near = spans.filter { $0.start - a < t1 && $0.end + r > t0 }
        guard !near.isEmpty else { return out }
        for k in 0..<count {
            let d = depth(at: Double(startFrame + k) / sr, spans: near, attack: a, release: r)
            if d > 0 { out[k] = gain(depth: d, amountDb: db) }
        }
        return out
    }
}

// MARK: - 編集(インスペクタ・メニュー)

/// ダッキングの編集の純粋な計算。変えたときだけ true(何も変わらない編集は Undo に登録しない)。
public enum DuckEditing {
    public static func supports(_ c: Clip) -> Bool { Clip.supportsDuck(c) }

    @discardableResult
    static func edit(_ c: inout Clip, _ change: (inout Duck) -> Void) -> Bool {
        guard supports(c) else { return false }
        let before = c.duck
        var d = before ?? Duck()
        change(&d)
        c.duck = d
        return c.duck != before
    }

    /// オン / オフ。オフは設定を残したまま切る。設定が何も無ければ `duck` ごと外す。
    @discardableResult
    public static func setEnabled(_ c: inout Clip, _ on: Bool) -> Bool {
        guard supports(c) else { return false }
        let before = c.duck
        if on {
            var d = before ?? Duck(); d.enabled = true; c.duck = d
        } else if var d = before {
            if d.hasNoSettings { c.duck = nil } else { d.enabled = false; c.duck = d }
        }
        return c.duck != before
    }

    public static func toggle(_ c: inout Clip) -> Bool { setEnabled(&c, !c.hasDuck) }

    private static func r1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
    private static func r2(_ v: Double) -> Double { (v * 100).rounded() / 100 }

    @discardableResult
    public static func setAmount(_ c: inout Clip, _ db: Double) -> Bool {
        let r = Duck.amountRange
        let x = r1(min(max(db.isFinite ? db : Duck.defaultAmount, r.lowerBound), r.upperBound))
        return edit(&c) { $0.amount = x }
    }

    @discardableResult
    public static func setAttack(_ c: inout Clip, _ s: Double) -> Bool {
        let r = Duck.attackRange
        let x = r2(min(max(s.isFinite ? s : Duck.defaultAttack, r.lowerBound), r.upperBound))
        return edit(&c) { $0.attack = x }
    }

    @discardableResult
    public static func setRelease(_ c: inout Clip, _ s: Double) -> Bool {
        let r = Duck.releaseRange
        let x = r2(min(max(s.isFinite ? s : Duck.defaultRelease, r.lowerBound), r.upperBound))
        return edit(&c) { $0.release = x }
    }
}
