import Foundation

// MARK: - 音声エフェクト(クリップごと)

/// クリップの音声エフェクト(イコライザー・コンプレッサー・リバーブ・ノーマライズ)。
/// どれも optional で、1 つも無ければ `audioFx` ごとファイルに書かない。知らないキーは `extra` に残して書き戻す。
/// 処理の順番は 速度(AudioRemap)→ EQ → コンプレッサー → リバーブ → ノーマライズ → 音量(キーフレーム)→ フェード → パン → ミックス。
public struct AudioFx: Codable, Equatable, Sendable {
    public var eq: EQ?
    public var compressor: Compressor?
    public var reverb: Reverb?
    public var normalize: Normalize?
    public var extra: [String: JSONValue] = [:]

    static let knownKeys: Set<String> = ["eq", "compressor", "reverb", "normalize"]

    public init(eq: EQ? = nil, compressor: Compressor? = nil, reverb: Reverb? = nil, normalize: Normalize? = nil) {
        self.eq = eq; self.compressor = compressor; self.reverb = reverb; self.normalize = normalize
    }

    /// 何も入っていない(ファイルに書かない)。
    public var isEmpty: Bool { eq == nil && compressor == nil && reverb == nil && normalize == nil && extra.isEmpty }

    /// 実際に音を変えるものが 1 つでもある。
    public var isActive: Bool {
        (eq?.isActive ?? false) || (compressor?.isActive ?? false) || (reverb?.isActive ?? false) || (normalize?.isActive ?? false)
    }

    /// EQ・コンプレッサー・リバーブのどれかが効く(ノーマライズだけのときは false)。
    public var hasChain: Bool { (eq?.isActive ?? false) || (compressor?.isActive ?? false) || (reverb?.isActive ?? false) }

    /// 音に効く項目だけから作る文字列(再生用ミックスの鍵に足す)。効かない項目や `enabled` が false のものは入れない。
    public var cacheToken: String {
        var parts: [String] = []
        if let e = eq, e.isActive { parts.append("eq=\(e.lowDb),\(e.midDb),\(e.highDb)") }
        if let c = compressor, c.isActive { parts.append("comp=\(c.thresholdDb),\(c.ratioValue),\(c.attackMs),\(c.releaseMs),\(String(describing: c.makeupDb))") }
        if let r = reverb, r.isActive { parts.append("rev=\(r.mix),\(r.sizeOrDefault.rawValue)") }
        if let n = normalize, n.isActive { parts.append("norm=\(n.targetDb),\(n.modeOrDefault.rawValue)") }
        return parts.joined(separator: ";")
    }

    // MARK: 3 バンド EQ

    /// 低域シェルフ(100 Hz)・中域ピーク(1 kHz、Q≈1)・高域シェルフ(8 kHz)。各 −12〜+12 dB。
    public struct EQ: Codable, Equatable, Sendable {
        public static let range: ClosedRange<Double> = -12...12
        public var low: Double?
        public var mid: Double?
        public var high: Double?
        public var extra: [String: JSONValue] = [:]
        static let knownKeys: Set<String> = ["low", "mid", "high"]

        public init(low: Double? = nil, mid: Double? = nil, high: Double? = nil) { self.low = low; self.mid = mid; self.high = high }

        public static func clampDb(_ v: Double) -> Double { v.isFinite ? min(max(v, range.lowerBound), range.upperBound) : 0 }
        public var lowDb: Double { Self.clampDb(low ?? 0) }
        public var midDb: Double { Self.clampDb(mid ?? 0) }
        public var highDb: Double { Self.clampDb(high ?? 0) }
        public var isFlat: Bool { lowDb == 0 && midDb == 0 && highDb == 0 }
        public var isActive: Bool { !isFlat }

        public init(from decoder: Decoder) throws {
            let l = Lenient(c: try decoder.container(keyedBy: AnyKey.self), known: Self.knownKeys)
            low = l.double("low"); mid = l.double("mid"); high = l.double("high")
            extra = l.extra()
        }

        /// 0 でない帯域だけ書く。
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: AnyKey.self)
            for (k, v) in extra { try c.encode(v, forKey: AnyKey(k)) }
            if let v = low, v != 0 { try c.encode(v, forKey: AnyKey("low")) }
            if let v = mid, v != 0 { try c.encode(v, forKey: AnyKey("mid")) }
            if let v = high, v != 0 { try c.encode(v, forKey: AnyKey("high")) }
        }
    }

    // MARK: コンプレッサー

    public struct Compressor: Codable, Equatable, Sendable {
        public static let thresholdRange: ClosedRange<Double> = -60...0
        public static let ratioRange: ClosedRange<Double> = 1...20
        public static let attackRange: ClosedRange<Double> = 1...200
        public static let releaseRange: ClosedRange<Double> = 10...1000
        public static let makeupRange: ClosedRange<Double> = 0...24
        public static let defaultThreshold = -18.0, defaultRatio = 3.0, defaultAttack = 10.0, defaultRelease = 120.0, defaultMakeup = 0.0

        /// false のときだけ書く(設定値は残したまま一時的に切る)。
        public var enabled: Bool = true
        public var threshold: Double?
        public var ratio: Double?
        public var attack: Double?
        public var release: Double?
        public var makeup: Double?
        public var extra: [String: JSONValue] = [:]
        static let knownKeys: Set<String> = ["enabled", "threshold", "ratio", "attack", "release", "makeup"]

        public init(threshold: Double? = nil, ratio: Double? = nil, attack: Double? = nil, release: Double? = nil, makeup: Double? = nil, enabled: Bool = true) {
            self.threshold = threshold; self.ratio = ratio; self.attack = attack; self.release = release; self.makeup = makeup; self.enabled = enabled
        }

        private static func clamp(_ v: Double?, _ r: ClosedRange<Double>, _ d: Double) -> Double {
            guard let v, v.isFinite else { return d }
            return min(max(v, r.lowerBound), r.upperBound)
        }
        public var thresholdDb: Double { Self.clamp(threshold, Self.thresholdRange, Self.defaultThreshold) }
        public var ratioValue: Double { Self.clamp(ratio, Self.ratioRange, Self.defaultRatio) }
        public var attackMs: Double { Self.clamp(attack, Self.attackRange, Self.defaultAttack) }
        public var releaseMs: Double { Self.clamp(release, Self.releaseRange, Self.defaultRelease) }
        public var makeupDb: Double { Self.clamp(makeup, Self.makeupRange, Self.defaultMakeup) }
        public var isActive: Bool { enabled }

        public init(from decoder: Decoder) throws {
            let l = Lenient(c: try decoder.container(keyedBy: AnyKey.self), known: Self.knownKeys)
            enabled = l.bool("enabled") ?? true
            threshold = l.double("threshold"); ratio = l.double("ratio"); attack = l.double("attack")
            release = l.double("release"); makeup = l.double("makeup")
            extra = l.extra()
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: AnyKey.self)
            for (k, v) in extra { try c.encode(v, forKey: AnyKey(k)) }
            if !enabled { try c.encode(false, forKey: AnyKey("enabled")) }
            try c.encodeIfPresent(threshold, forKey: AnyKey("threshold"))
            try c.encodeIfPresent(ratio, forKey: AnyKey("ratio"))
            try c.encodeIfPresent(attack, forKey: AnyKey("attack"))
            try c.encodeIfPresent(release, forKey: AnyKey("release"))
            try c.encodeIfPresent(makeup, forKey: AnyKey("makeup"))
        }
    }

    // MARK: リバーブ

    public enum ReverbSize: String, CaseIterable, Sendable {
        case small, medium, large, hall
        public var label: String {
            switch self { case .small: return "小"; case .medium: return "中"; case .large: return "大"; case .hall: return "ホール" }
        }
    }

    public struct Reverb: Codable, Equatable, Sendable {
        public static let mixRange: ClosedRange<Double> = 0...1
        public static let defaultMix = 0.25
        public var enabled: Bool = true
        public var mixValue: Double?
        /// "small" / "medium" / "large" / "hall"。知らない文字列は medium として鳴らし、そのまま書き戻す。
        public var size: String?
        public var extra: [String: JSONValue] = [:]
        static let knownKeys: Set<String> = ["enabled", "mix", "size"]

        public init(mix: Double? = nil, size: ReverbSize? = nil, enabled: Bool = true) {
            self.mixValue = mix; self.size = size?.rawValue; self.enabled = enabled
        }

        public var mix: Double {
            guard let v = mixValue, v.isFinite else { return Self.defaultMix }
            return min(max(v, 0), 1)
        }
        public var sizeOrDefault: ReverbSize { size.flatMap(ReverbSize.init(rawValue:)) ?? .medium }
        /// ドライだけ(mix = 0)のときは効かない。
        public var isActive: Bool { enabled && mix > 0 }

        public init(from decoder: Decoder) throws {
            let l = Lenient(c: try decoder.container(keyedBy: AnyKey.self), known: Self.knownKeys)
            enabled = l.bool("enabled") ?? true
            mixValue = l.double("mix"); size = l.string("size")
            extra = l.extra()
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: AnyKey.self)
            for (k, v) in extra { try c.encode(v, forKey: AnyKey(k)) }
            if !enabled { try c.encode(false, forKey: AnyKey("enabled")) }
            try c.encodeIfPresent(mixValue, forKey: AnyKey("mix"))
            try c.encodeIfPresent(size, forKey: AnyKey("size"))
        }
    }

    // MARK: ノーマライズ

    public enum NormalizeMode: String, CaseIterable, Sendable {
        case peak, loudness
        public var label: String { self == .peak ? "ピーク" : "ラウドネス" }
    }

    public struct Normalize: Codable, Equatable, Sendable {
        public static let peakRange: ClosedRange<Double> = -30...0
        public static let loudnessRange: ClosedRange<Double> = -23 ... -9
        public static let defaultTarget = -1.0
        public var enabled: Bool = true
        public var target: Double?
        /// "peak"(既定)/ "loudness"。知らない文字列は peak として扱い、そのまま書き戻す。
        public var mode: String?
        public var extra: [String: JSONValue] = [:]
        static let knownKeys: Set<String> = ["enabled", "targetDb", "mode"]

        public init(targetDb: Double? = nil, mode: NormalizeMode? = nil, enabled: Bool = true) {
            self.target = targetDb; self.mode = mode?.rawValue; self.enabled = enabled
        }

        public var modeOrDefault: NormalizeMode { mode.flatMap(NormalizeMode.init(rawValue:)) ?? .peak }
        public static func range(for mode: NormalizeMode) -> ClosedRange<Double> { mode == .peak ? peakRange : loudnessRange }
        /// モードごとの範囲に収めた目標(ピーク dBFS / ラウドネス LUFS)。
        public var targetDb: Double {
            let m = modeOrDefault
            let r = Self.range(for: m)
            guard let t = target, t.isFinite else { return m == .peak ? Self.defaultTarget : -16 }
            return min(max(t, r.lowerBound), r.upperBound)
        }
        public var isActive: Bool { enabled }

        public init(from decoder: Decoder) throws {
            let l = Lenient(c: try decoder.container(keyedBy: AnyKey.self), known: Self.knownKeys)
            enabled = l.bool("enabled") ?? true
            target = l.double("targetDb"); mode = l.string("mode")
            extra = l.extra()
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: AnyKey.self)
            for (k, v) in extra { try c.encode(v, forKey: AnyKey(k)) }
            if !enabled { try c.encode(false, forKey: AnyKey("enabled")) }
            try c.encodeIfPresent(target, forKey: AnyKey("targetDb"))
            try c.encodeIfPresent(mode, forKey: AnyKey("mode"))
        }
    }

    // MARK: Codable

    public init(from decoder: Decoder) throws {
        let l = Lenient(c: try decoder.container(keyedBy: AnyKey.self), known: Self.knownKeys)
        eq = l.value("eq"); compressor = l.value("compressor"); reverb = l.value("reverb"); normalize = l.value("normalize")
        extra = l.extra()
        // 読めなかった項目は捨てずに、そのまま書き戻す
        for key in Self.knownKeys {
            guard let raw: JSONValue = l.value(key) else { continue }
            let ok: Bool
            switch key {
            case "eq": ok = eq != nil
            case "compressor": ok = compressor != nil
            case "reverb": ok = reverb != nil
            default: ok = normalize != nil
            }
            if !ok { extra[key] = raw }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        for (k, v) in extra { try c.encode(v, forKey: AnyKey(k)) }
        try c.encodeIfPresent(eq, forKey: AnyKey("eq"))
        try c.encodeIfPresent(compressor, forKey: AnyKey("compressor"))
        try c.encodeIfPresent(reverb, forKey: AnyKey("reverb"))
        try c.encodeIfPresent(normalize, forKey: AnyKey("normalize"))
    }
}

// MARK: - クリップ側の読み出し

public extension Clip {
    /// 左右の振り分け(−1 = 左いっぱい … 1 = 右いっぱい)。未設定 = 0(中央)。
    var panOrDefault: Double {
        guard let p = pan, p.isFinite else { return 0 }
        return min(max(p, -1), 1)
    }
    /// 音に効くエフェクトがある。
    var hasAudioFx: Bool { audioFx?.isActive ?? false }
    var hasPan: Bool { panOrDefault != 0 }
    /// 音量にキーがある。
    var hasVolumeKeys: Bool { !(keyframes["volume"]?.isEmpty ?? true) }

    /// 音声の処理を受けられるクリップ(音声・ボイス・動画。フリーズフレームは無音)。
    static func supportsAudioFx(_ c: Clip) -> Bool {
        (c.type == .audio || c.type == .voice || c.type == .video) && !c.isFreeze
    }
}
