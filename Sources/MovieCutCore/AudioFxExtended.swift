import Foundation

// MARK: - 音声エフェクト拡張(第3波バッチK: YMM4監査 #65 の残り + #66 の土台)
//
// 既存の `AudioFx`(EQ・コンプレッサー・リバーブ・ディレイ・ノーマライズ・ノイズ除去・
// 音程・ゲート・リミッター)に足りなかったエフェクト群を、1 つの任意項目 `extended` の中に
// 追加方式で入れる。`extended` が無い/空のクリップは、従来と完全に同じ音・同じファイルになる。
// 処理の順番は AudioFxChain の中で「既存チェーン(ディレイまで)→ 拡張チェーン → リミッター」。
// 拡張チェーン内部の順番は フィルタ(HP→LP→BP→ノッチ)→ パラメトリックEQ → ディストーション →
// チューブ → ワウ → コーラス → フランジャー → フェイザー → トレモロ → ビブラート → エコー →
// ロボット → 低音質化 で固定(ドキュメント docs/音声エフェクト対応表.md 参照)。

public extension AudioFx {
    /// フィルタの種類(YMM4 の ハイパス/ローパス/バンドパス/ノッチ に対応する 4 スロット)。
    enum FilterKind: String, CaseIterable, Sendable {
        case lowPass, highPass, bandPass, notch
        public var label: String {
            switch self {
            case .lowPass: return "ローパス"
            case .highPass: return "ハイパス"
            case .bandPass: return "バンドパス"
            case .notch: return "ノッチ"
            }
        }
        /// そのスロットの既定の中心/カットオフ周波数(Hz)。
        public var defaultFreq: Double {
            switch self {
            case .lowPass: return 12000
            case .highPass: return 80
            case .bandPass: return 1000
            case .notch: return 1000
            }
        }
        /// そのスロットの既定の Q。
        public var defaultQ: Double {
            switch self {
            case .lowPass, .highPass: return 0.707
            case .bandPass: return 1
            case .notch: return 8
            }
        }
    }

    // MARK: フィルタ(1 スロットぶん)

    /// 2 次フィルタ(RBJ)1 つぶんの設定。周波数と Q だけを持ち、種類は置くスロットで決まる。
    struct Filter: Codable, Equatable, Sendable {
        public static let freqRange: ClosedRange<Double> = 20...20000
        public static let qRange: ClosedRange<Double> = 0.3...20
        /// false のときだけ書く(設定値は残したまま一時的に切る)。
        public var enabled: Bool = true
        public var freq: Double?
        public var q: Double?
        public var extra: [String: JSONValue] = [:]
        static let knownKeys: Set<String> = ["enabled", "freq", "q"]

        public init(freq: Double? = nil, q: Double? = nil, enabled: Bool = true) {
            self.freq = freq; self.q = q; self.enabled = enabled
        }
        public func freqOr(_ d: Double) -> Double {
            guard let v = freq, v.isFinite else { return d }
            return min(max(v, Self.freqRange.lowerBound), Self.freqRange.upperBound)
        }
        public func qOr(_ d: Double) -> Double {
            guard let v = q, v.isFinite else { return d }
            return min(max(v, Self.qRange.lowerBound), Self.qRange.upperBound)
        }
        public var isActive: Bool { enabled }

        public init(from decoder: Decoder) throws {
            let l = Lenient(c: try decoder.container(keyedBy: AnyKey.self), known: Self.knownKeys)
            enabled = l.bool("enabled") ?? true
            freq = l.double("freq"); q = l.double("q")
            extra = l.extra()
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: AnyKey.self)
            for (k, v) in extra { try c.encode(v, forKey: AnyKey(k)) }
            if !enabled { try c.encode(false, forKey: AnyKey("enabled")) }
            try c.encodeIfPresent(freq, forKey: AnyKey("freq"))
            try c.encodeIfPresent(q, forKey: AnyKey("q"))
        }
    }

    // MARK: パラメトリック EQ(5 バンド)

    /// 固定周波数(60 / 250 / 1k / 4k / 12k Hz、Q = 1)のピーキング 5 バンド。各 −12〜+12 dB。
    /// 3 バンド EQ とは別に持てる(YMM4 の「イコライザ」相当を厚くする)。
    struct ParametricEQ: Codable, Equatable, Sendable {
        public static let range: ClosedRange<Double> = -12...12
        public static let frequencies: [Double] = [60, 250, 1000, 4000, 12000]
        public var g60: Double?
        public var g250: Double?
        public var g1000: Double?
        public var g4000: Double?
        public var g12000: Double?
        public var extra: [String: JSONValue] = [:]
        static let knownKeys: Set<String> = ["g60", "g250", "g1000", "g4000", "g12000"]

        public init(g60: Double? = nil, g250: Double? = nil, g1000: Double? = nil, g4000: Double? = nil, g12000: Double? = nil) {
            self.g60 = g60; self.g250 = g250; self.g1000 = g1000; self.g4000 = g4000; self.g12000 = g12000
        }
        public static func clampDb(_ v: Double) -> Double { v.isFinite ? min(max(v, range.lowerBound), range.upperBound) : 0 }
        /// バンド番号(0〜4)ごとの利得(dB、範囲に収めた値)。
        public func gain(_ band: Int) -> Double {
            switch band {
            case 0: return Self.clampDb(g60 ?? 0)
            case 1: return Self.clampDb(g250 ?? 0)
            case 2: return Self.clampDb(g1000 ?? 0)
            case 3: return Self.clampDb(g4000 ?? 0)
            default: return Self.clampDb(g12000 ?? 0)
            }
        }
        public var gains: [Double] { (0..<5).map { gain($0) } }
        public var isFlat: Bool { gains.allSatisfy { $0 == 0 } }
        public var isActive: Bool { !isFlat }

        public init(from decoder: Decoder) throws {
            let l = Lenient(c: try decoder.container(keyedBy: AnyKey.self), known: Self.knownKeys)
            g60 = l.double("g60"); g250 = l.double("g250"); g1000 = l.double("g1000"); g4000 = l.double("g4000"); g12000 = l.double("g12000")
            extra = l.extra()
        }
        /// 0 でない帯域だけ書く。
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: AnyKey.self)
            for (k, v) in extra { try c.encode(v, forKey: AnyKey(k)) }
            if let v = g60, v != 0 { try c.encode(v, forKey: AnyKey("g60")) }
            if let v = g250, v != 0 { try c.encode(v, forKey: AnyKey("g250")) }
            if let v = g1000, v != 0 { try c.encode(v, forKey: AnyKey("g1000")) }
            if let v = g4000, v != 0 { try c.encode(v, forKey: AnyKey("g4000")) }
            if let v = g12000, v != 0 { try c.encode(v, forKey: AnyKey("g12000")) }
        }
    }

    // MARK: ディストーション / チューブ

    /// 歪み(tanh のソフトクリップ)。drive は入力にかける利得(dB)、mix は歪んだ音の混ぜ具合。
    struct Distortion: Codable, Equatable, Sendable {
        public static let driveRange: ClosedRange<Double> = 0...40
        public static let mixRange: ClosedRange<Double> = 0...1
        public static let defaultDrive = 18.0, defaultMix = 0.8
        public var enabled: Bool = true
        public var drive: Double?
        public var mixValue: Double?
        public var extra: [String: JSONValue] = [:]
        static let knownKeys: Set<String> = ["enabled", "drive", "mix"]

        public init(drive: Double? = nil, mix: Double? = nil, enabled: Bool = true) {
            self.drive = drive; self.mixValue = mix; self.enabled = enabled
        }
        private static func clamp(_ v: Double?, _ r: ClosedRange<Double>, _ d: Double) -> Double {
            guard let v, v.isFinite else { return d }
            return min(max(v, r.lowerBound), r.upperBound)
        }
        public var driveDb: Double { Self.clamp(drive, Self.driveRange, Self.defaultDrive) }
        public var mix: Double { Self.clamp(mixValue, Self.mixRange, Self.defaultMix) }
        public var isActive: Bool { enabled && mix > 0 }

        public init(from decoder: Decoder) throws {
            let l = Lenient(c: try decoder.container(keyedBy: AnyKey.self), known: Self.knownKeys)
            enabled = l.bool("enabled") ?? true
            drive = l.double("drive"); mixValue = l.double("mix")
            extra = l.extra()
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: AnyKey.self)
            for (k, v) in extra { try c.encode(v, forKey: AnyKey(k)) }
            if !enabled { try c.encode(false, forKey: AnyKey("enabled")) }
            try c.encodeIfPresent(drive, forKey: AnyKey("drive"))
            try c.encodeIfPresent(mixValue, forKey: AnyKey("mix"))
        }
    }

    /// チューブ(真空管)歪みの近似。非対称なソフトクリップ(偶数倍音が出る)+ 高域を少し落とす温かみ。
    struct Tube: Codable, Equatable, Sendable {
        public static let driveRange: ClosedRange<Double> = 0...36
        public static let mixRange: ClosedRange<Double> = 0...1
        public static let defaultDrive = 12.0, defaultMix = 0.8
        public var enabled: Bool = true
        public var drive: Double?
        public var mixValue: Double?
        public var extra: [String: JSONValue] = [:]
        static let knownKeys: Set<String> = ["enabled", "drive", "mix"]

        public init(drive: Double? = nil, mix: Double? = nil, enabled: Bool = true) {
            self.drive = drive; self.mixValue = mix; self.enabled = enabled
        }
        private static func clamp(_ v: Double?, _ r: ClosedRange<Double>, _ d: Double) -> Double {
            guard let v, v.isFinite else { return d }
            return min(max(v, r.lowerBound), r.upperBound)
        }
        public var driveDb: Double { Self.clamp(drive, Self.driveRange, Self.defaultDrive) }
        public var mix: Double { Self.clamp(mixValue, Self.mixRange, Self.defaultMix) }
        public var isActive: Bool { enabled && mix > 0 }

        public init(from decoder: Decoder) throws {
            let l = Lenient(c: try decoder.container(keyedBy: AnyKey.self), known: Self.knownKeys)
            enabled = l.bool("enabled") ?? true
            drive = l.double("drive"); mixValue = l.double("mix")
            extra = l.extra()
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: AnyKey.self)
            for (k, v) in extra { try c.encode(v, forKey: AnyKey(k)) }
            if !enabled { try c.encode(false, forKey: AnyKey("enabled")) }
            try c.encodeIfPresent(drive, forKey: AnyKey("drive"))
            try c.encodeIfPresent(mixValue, forKey: AnyKey("mix"))
        }
    }

    // MARK: コーラス / フランジャー

    /// コーラス。遅延(約 18 ms)を LFO で揺らした音を重ねる。
    struct Chorus: Codable, Equatable, Sendable {
        public static let rateRange: ClosedRange<Double> = 0.05...10
        public static let depthRange: ClosedRange<Double> = 0...1
        public static let mixRange: ClosedRange<Double> = 0...1
        public static let defaultRate = 1.0, defaultDepth = 0.5, defaultMix = 0.5
        public var enabled: Bool = true
        public var rate: Double?
        public var depth: Double?
        public var mixValue: Double?
        public var extra: [String: JSONValue] = [:]
        static let knownKeys: Set<String> = ["enabled", "rate", "depth", "mix"]

        public init(rate: Double? = nil, depth: Double? = nil, mix: Double? = nil, enabled: Bool = true) {
            self.rate = rate; self.depth = depth; self.mixValue = mix; self.enabled = enabled
        }
        private static func clamp(_ v: Double?, _ r: ClosedRange<Double>, _ d: Double) -> Double {
            guard let v, v.isFinite else { return d }
            return min(max(v, r.lowerBound), r.upperBound)
        }
        public var rateHz: Double { Self.clamp(rate, Self.rateRange, Self.defaultRate) }
        public var depthValue: Double { Self.clamp(depth, Self.depthRange, Self.defaultDepth) }
        public var mix: Double { Self.clamp(mixValue, Self.mixRange, Self.defaultMix) }
        public var isActive: Bool { enabled && mix > 0 && depthValue > 0 }

        public init(from decoder: Decoder) throws {
            let l = Lenient(c: try decoder.container(keyedBy: AnyKey.self), known: Self.knownKeys)
            enabled = l.bool("enabled") ?? true
            rate = l.double("rate"); depth = l.double("depth"); mixValue = l.double("mix")
            extra = l.extra()
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: AnyKey.self)
            for (k, v) in extra { try c.encode(v, forKey: AnyKey(k)) }
            if !enabled { try c.encode(false, forKey: AnyKey("enabled")) }
            try c.encodeIfPresent(rate, forKey: AnyKey("rate"))
            try c.encodeIfPresent(depth, forKey: AnyKey("depth"))
            try c.encodeIfPresent(mixValue, forKey: AnyKey("mix"))
        }
    }

    /// フランジャー。ごく短い遅延(約 2.5 ms)を LFO で揺らし、フィードバックで櫛状のうねりを作る。
    struct Flanger: Codable, Equatable, Sendable {
        public static let rateRange: ClosedRange<Double> = 0.05...10
        public static let depthRange: ClosedRange<Double> = 0...1
        public static let feedbackRange: ClosedRange<Double> = 0...0.9
        public static let mixRange: ClosedRange<Double> = 0...1
        public static let defaultRate = 0.4, defaultDepth = 0.7, defaultFeedback = 0.5, defaultMix = 0.5
        public var enabled: Bool = true
        public var rate: Double?
        public var depth: Double?
        public var feedback: Double?
        public var mixValue: Double?
        public var extra: [String: JSONValue] = [:]
        static let knownKeys: Set<String> = ["enabled", "rate", "depth", "feedback", "mix"]

        public init(rate: Double? = nil, depth: Double? = nil, feedback: Double? = nil, mix: Double? = nil, enabled: Bool = true) {
            self.rate = rate; self.depth = depth; self.feedback = feedback; self.mixValue = mix; self.enabled = enabled
        }
        private static func clamp(_ v: Double?, _ r: ClosedRange<Double>, _ d: Double) -> Double {
            guard let v, v.isFinite else { return d }
            return min(max(v, r.lowerBound), r.upperBound)
        }
        public var rateHz: Double { Self.clamp(rate, Self.rateRange, Self.defaultRate) }
        public var depthValue: Double { Self.clamp(depth, Self.depthRange, Self.defaultDepth) }
        public var feedbackValue: Double { Self.clamp(feedback, Self.feedbackRange, Self.defaultFeedback) }
        public var mix: Double { Self.clamp(mixValue, Self.mixRange, Self.defaultMix) }
        public var isActive: Bool { enabled && mix > 0 && depthValue > 0 }

        public init(from decoder: Decoder) throws {
            let l = Lenient(c: try decoder.container(keyedBy: AnyKey.self), known: Self.knownKeys)
            enabled = l.bool("enabled") ?? true
            rate = l.double("rate"); depth = l.double("depth"); feedback = l.double("feedback"); mixValue = l.double("mix")
            extra = l.extra()
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: AnyKey.self)
            for (k, v) in extra { try c.encode(v, forKey: AnyKey(k)) }
            if !enabled { try c.encode(false, forKey: AnyKey("enabled")) }
            try c.encodeIfPresent(rate, forKey: AnyKey("rate"))
            try c.encodeIfPresent(depth, forKey: AnyKey("depth"))
            try c.encodeIfPresent(feedback, forKey: AnyKey("feedback"))
            try c.encodeIfPresent(mixValue, forKey: AnyKey("mix"))
        }
    }

    // MARK: フェイザー / トレモロ / ビブラート

    /// フェイザー。オールパス 4 段の位相ずらしを LFO で掃引する。depth は掃引の幅と共鳴の強さ。
    struct Phaser: Codable, Equatable, Sendable {
        public static let rateRange: ClosedRange<Double> = 0.05...10
        public static let depthRange: ClosedRange<Double> = 0...1
        public static let mixRange: ClosedRange<Double> = 0...1
        public static let defaultRate = 0.6, defaultDepth = 0.6, defaultMix = 0.5
        public var enabled: Bool = true
        public var rate: Double?
        public var depth: Double?
        public var mixValue: Double?
        public var extra: [String: JSONValue] = [:]
        static let knownKeys: Set<String> = ["enabled", "rate", "depth", "mix"]

        public init(rate: Double? = nil, depth: Double? = nil, mix: Double? = nil, enabled: Bool = true) {
            self.rate = rate; self.depth = depth; self.mixValue = mix; self.enabled = enabled
        }
        private static func clamp(_ v: Double?, _ r: ClosedRange<Double>, _ d: Double) -> Double {
            guard let v, v.isFinite else { return d }
            return min(max(v, r.lowerBound), r.upperBound)
        }
        public var rateHz: Double { Self.clamp(rate, Self.rateRange, Self.defaultRate) }
        public var depthValue: Double { Self.clamp(depth, Self.depthRange, Self.defaultDepth) }
        public var mix: Double { Self.clamp(mixValue, Self.mixRange, Self.defaultMix) }
        public var isActive: Bool { enabled && mix > 0 && depthValue > 0 }

        public init(from decoder: Decoder) throws {
            let l = Lenient(c: try decoder.container(keyedBy: AnyKey.self), known: Self.knownKeys)
            enabled = l.bool("enabled") ?? true
            rate = l.double("rate"); depth = l.double("depth"); mixValue = l.double("mix")
            extra = l.extra()
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: AnyKey.self)
            for (k, v) in extra { try c.encode(v, forKey: AnyKey(k)) }
            if !enabled { try c.encode(false, forKey: AnyKey("enabled")) }
            try c.encodeIfPresent(rate, forKey: AnyKey("rate"))
            try c.encodeIfPresent(depth, forKey: AnyKey("depth"))
            try c.encodeIfPresent(mixValue, forKey: AnyKey("mix"))
        }
    }

    /// トレモロ。音量を LFO で揺らす。depth 1 で一番静かな所が無音になる。
    struct Tremolo: Codable, Equatable, Sendable {
        public static let rateRange: ClosedRange<Double> = 0.1...20
        public static let depthRange: ClosedRange<Double> = 0...1
        public static let defaultRate = 5.0, defaultDepth = 0.5
        public var enabled: Bool = true
        public var rate: Double?
        public var depth: Double?
        public var extra: [String: JSONValue] = [:]
        static let knownKeys: Set<String> = ["enabled", "rate", "depth"]

        public init(rate: Double? = nil, depth: Double? = nil, enabled: Bool = true) {
            self.rate = rate; self.depth = depth; self.enabled = enabled
        }
        private static func clamp(_ v: Double?, _ r: ClosedRange<Double>, _ d: Double) -> Double {
            guard let v, v.isFinite else { return d }
            return min(max(v, r.lowerBound), r.upperBound)
        }
        public var rateHz: Double { Self.clamp(rate, Self.rateRange, Self.defaultRate) }
        public var depthValue: Double { Self.clamp(depth, Self.depthRange, Self.defaultDepth) }
        public var isActive: Bool { enabled && depthValue > 0 }

        public init(from decoder: Decoder) throws {
            let l = Lenient(c: try decoder.container(keyedBy: AnyKey.self), known: Self.knownKeys)
            enabled = l.bool("enabled") ?? true
            rate = l.double("rate"); depth = l.double("depth")
            extra = l.extra()
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: AnyKey.self)
            for (k, v) in extra { try c.encode(v, forKey: AnyKey(k)) }
            if !enabled { try c.encode(false, forKey: AnyKey("enabled")) }
            try c.encodeIfPresent(rate, forKey: AnyKey("rate"))
            try c.encodeIfPresent(depth, forKey: AnyKey("depth"))
        }
    }

    /// ビブラート。遅延を LFO で揺らし、遅れた音だけを出す(音程が揺れる)。depth は揺れ幅(ms)。
    struct Vibrato: Codable, Equatable, Sendable {
        public static let rateRange: ClosedRange<Double> = 0.1...20
        public static let depthRange: ClosedRange<Double> = 0...10
        public static let defaultRate = 5.0, defaultDepth = 3.0
        public var enabled: Bool = true
        public var rate: Double?
        public var depth: Double?
        public var extra: [String: JSONValue] = [:]
        static let knownKeys: Set<String> = ["enabled", "rate", "depth"]

        public init(rate: Double? = nil, depth: Double? = nil, enabled: Bool = true) {
            self.rate = rate; self.depth = depth; self.enabled = enabled
        }
        private static func clamp(_ v: Double?, _ r: ClosedRange<Double>, _ d: Double) -> Double {
            guard let v, v.isFinite else { return d }
            return min(max(v, r.lowerBound), r.upperBound)
        }
        public var rateHz: Double { Self.clamp(rate, Self.rateRange, Self.defaultRate) }
        /// 揺れ幅(ms)。
        public var depthMs: Double { Self.clamp(depth, Self.depthRange, Self.defaultDepth) }
        public var isActive: Bool { enabled && depthMs > 0 }

        public init(from decoder: Decoder) throws {
            let l = Lenient(c: try decoder.container(keyedBy: AnyKey.self), known: Self.knownKeys)
            enabled = l.bool("enabled") ?? true
            rate = l.double("rate"); depth = l.double("depth")
            extra = l.extra()
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: AnyKey.self)
            for (k, v) in extra { try c.encode(v, forKey: AnyKey(k)) }
            if !enabled { try c.encode(false, forKey: AnyKey("enabled")) }
            try c.encodeIfPresent(rate, forKey: AnyKey("rate"))
            try c.encodeIfPresent(depth, forKey: AnyKey("depth"))
        }
    }

    // MARK: ワウ / オートワウ

    /// ワウ。共鳴のあるピーキングフィルタの周波数を掃引する。
    /// 手動(auto = false)は position(0〜1)で固定、オートワウ(auto = true)は音量の包絡で動き、
    /// sensitivity が包絡への追従の強さ。auto は true のときだけ書く。
    struct Wah: Codable, Equatable, Sendable {
        public static let positionRange: ClosedRange<Double> = 0...1
        public static let sensitivityRange: ClosedRange<Double> = 0...1
        public static let defaultPosition = 0.5, defaultSensitivity = 0.5
        public var enabled: Bool = true
        public var auto: Bool = false
        public var position: Double?
        public var sensitivity: Double?
        public var extra: [String: JSONValue] = [:]
        static let knownKeys: Set<String> = ["enabled", "auto", "position", "sensitivity"]

        public init(auto: Bool = false, position: Double? = nil, sensitivity: Double? = nil, enabled: Bool = true) {
            self.auto = auto; self.position = position; self.sensitivity = sensitivity; self.enabled = enabled
        }
        private static func clamp(_ v: Double?, _ r: ClosedRange<Double>, _ d: Double) -> Double {
            guard let v, v.isFinite else { return d }
            return min(max(v, r.lowerBound), r.upperBound)
        }
        public var positionValue: Double { Self.clamp(position, Self.positionRange, Self.defaultPosition) }
        public var sensitivityValue: Double { Self.clamp(sensitivity, Self.sensitivityRange, Self.defaultSensitivity) }
        public var isActive: Bool { enabled }
        /// position / 包絡(0〜1)からフィルタ周波数(Hz)。300〜3000 を対数で結ぶ。
        public static func frequency(forPosition p: Double) -> Double {
            let t = min(max(p.isFinite ? p : 0.5, 0), 1)
            return 300 * pow(10, t)   // 300 → 3000
        }

        public init(from decoder: Decoder) throws {
            let l = Lenient(c: try decoder.container(keyedBy: AnyKey.self), known: Self.knownKeys)
            enabled = l.bool("enabled") ?? true
            auto = l.bool("auto") ?? false
            position = l.double("position"); sensitivity = l.double("sensitivity")
            extra = l.extra()
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: AnyKey.self)
            for (k, v) in extra { try c.encode(v, forKey: AnyKey(k)) }
            if !enabled { try c.encode(false, forKey: AnyKey("enabled")) }
            if auto { try c.encode(true, forKey: AnyKey("auto")) }
            try c.encodeIfPresent(position, forKey: AnyKey("position"))
            try c.encodeIfPresent(sensitivity, forKey: AnyKey("sensitivity"))
        }
    }

    // MARK: エコー

    /// エコー。ディレイと違い、繰り返しのたびに高域が落ちる(ローパス付きフィードバック)柔らかい残響。
    struct Echo: Codable, Equatable, Sendable {
        public static let timeRange: ClosedRange<Double> = 0.03...2
        public static let feedbackRange: ClosedRange<Double> = 0...0.85
        public static let mixRange: ClosedRange<Double> = 0...1
        public static let defaultTime = 0.375, defaultFeedback = 0.45, defaultMix = 0.35
        public var enabled: Bool = true
        public var time: Double?
        public var feedback: Double?
        public var mixValue: Double?
        public var extra: [String: JSONValue] = [:]
        static let knownKeys: Set<String> = ["enabled", "time", "feedback", "mix"]

        public init(time: Double? = nil, feedback: Double? = nil, mix: Double? = nil, enabled: Bool = true) {
            self.time = time; self.feedback = feedback; self.mixValue = mix; self.enabled = enabled
        }
        private static func clamp(_ v: Double?, _ r: ClosedRange<Double>, _ d: Double) -> Double {
            guard let v, v.isFinite else { return d }
            return min(max(v, r.lowerBound), r.upperBound)
        }
        public var timeSeconds: Double { Self.clamp(time, Self.timeRange, Self.defaultTime) }
        public var feedbackValue: Double { Self.clamp(feedback, Self.feedbackRange, Self.defaultFeedback) }
        public var mix: Double { Self.clamp(mixValue, Self.mixRange, Self.defaultMix) }
        public var isActive: Bool { enabled && mix > 0 }

        public init(from decoder: Decoder) throws {
            let l = Lenient(c: try decoder.container(keyedBy: AnyKey.self), known: Self.knownKeys)
            enabled = l.bool("enabled") ?? true
            time = l.double("time"); feedback = l.double("feedback"); mixValue = l.double("mix")
            extra = l.extra()
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: AnyKey.self)
            for (k, v) in extra { try c.encode(v, forKey: AnyKey(k)) }
            if !enabled { try c.encode(false, forKey: AnyKey("enabled")) }
            try c.encodeIfPresent(time, forKey: AnyKey("time"))
            try c.encodeIfPresent(feedback, forKey: AnyKey("feedback"))
            try c.encodeIfPresent(mixValue, forKey: AnyKey("mix"))
        }
    }

    // MARK: 低音質化 / ロボット化

    /// 低音質化。ビット深度を落とし(量子化)、サンプルレートを落とす(ホールド)。
    struct LowQuality: Codable, Equatable, Sendable {
        public static let bitsRange: ClosedRange<Double> = 2...16
        public static let downsampleRange: ClosedRange<Double> = 1...32
        public static let defaultBits = 8.0, defaultDownsample = 4.0
        public var enabled: Bool = true
        public var bits: Double?
        public var downsample: Double?
        public var extra: [String: JSONValue] = [:]
        static let knownKeys: Set<String> = ["enabled", "bits", "downsample"]

        public init(bits: Double? = nil, downsample: Double? = nil, enabled: Bool = true) {
            self.bits = bits; self.downsample = downsample; self.enabled = enabled
        }
        private static func clamp(_ v: Double?, _ r: ClosedRange<Double>, _ d: Double) -> Double {
            guard let v, v.isFinite else { return d }
            return min(max(v, r.lowerBound), r.upperBound)
        }
        public var bitsValue: Int { Int(Self.clamp(bits, Self.bitsRange, Self.defaultBits).rounded()) }
        public var downsampleValue: Int { Int(Self.clamp(downsample, Self.downsampleRange, Self.defaultDownsample).rounded()) }
        /// 16 bit・等倍なら音は変わらない。
        public var isActive: Bool { enabled && (bitsValue < 16 || downsampleValue > 1) }

        public init(from decoder: Decoder) throws {
            let l = Lenient(c: try decoder.container(keyedBy: AnyKey.self), known: Self.knownKeys)
            enabled = l.bool("enabled") ?? true
            bits = l.double("bits"); downsample = l.double("downsample")
            extra = l.extra()
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: AnyKey.self)
            for (k, v) in extra { try c.encode(v, forKey: AnyKey(k)) }
            if !enabled { try c.encode(false, forKey: AnyKey("enabled")) }
            try c.encodeIfPresent(bits, forKey: AnyKey("bits"))
            try c.encodeIfPresent(downsample, forKey: AnyKey("downsample"))
        }
    }

    /// ロボット化の近似。リング変調(搬送波との乗算)で金属的な声にする。
    /// YMM4 のロボット化の内部方式は非公開のため、古典的なリング変調で近似する(限界は docs 参照)。
    struct Robot: Codable, Equatable, Sendable {
        public static let frequencyRange: ClosedRange<Double> = 10...300
        public static let mixRange: ClosedRange<Double> = 0...1
        public static let defaultFrequency = 50.0, defaultMix = 0.9
        public var enabled: Bool = true
        public var frequency: Double?
        public var mixValue: Double?
        public var extra: [String: JSONValue] = [:]
        static let knownKeys: Set<String> = ["enabled", "frequency", "mix"]

        public init(frequency: Double? = nil, mix: Double? = nil, enabled: Bool = true) {
            self.frequency = frequency; self.mixValue = mix; self.enabled = enabled
        }
        private static func clamp(_ v: Double?, _ r: ClosedRange<Double>, _ d: Double) -> Double {
            guard let v, v.isFinite else { return d }
            return min(max(v, r.lowerBound), r.upperBound)
        }
        public var frequencyHz: Double { Self.clamp(frequency, Self.frequencyRange, Self.defaultFrequency) }
        public var mix: Double { Self.clamp(mixValue, Self.mixRange, Self.defaultMix) }
        public var isActive: Bool { enabled && mix > 0 }

        public init(from decoder: Decoder) throws {
            let l = Lenient(c: try decoder.container(keyedBy: AnyKey.self), known: Self.knownKeys)
            enabled = l.bool("enabled") ?? true
            frequency = l.double("frequency"); mixValue = l.double("mix")
            extra = l.extra()
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: AnyKey.self)
            for (k, v) in extra { try c.encode(v, forKey: AnyKey(k)) }
            if !enabled { try c.encode(false, forKey: AnyKey("enabled")) }
            try c.encodeIfPresent(frequency, forKey: AnyKey("frequency"))
            try c.encodeIfPresent(mixValue, forKey: AnyKey("mix"))
        }
    }

    // MARK: 拡張コンテナ

    /// 追加エフェクトの入れ物。どれも任意で、全部空なら `extended` ごと書かない。
    struct Extended: Codable, Equatable, Sendable {
        public var lowPass: Filter?
        public var highPass: Filter?
        public var bandPass: Filter?
        public var notch: Filter?
        public var equalizer: ParametricEQ?
        public var distortion: Distortion?
        public var tube: Tube?
        public var chorus: Chorus?
        public var flanger: Flanger?
        public var phaser: Phaser?
        public var tremolo: Tremolo?
        public var vibrato: Vibrato?
        public var wah: Wah?
        public var echo: Echo?
        public var lowQuality: LowQuality?
        public var robot: Robot?
        public var extra: [String: JSONValue] = [:]

        static let knownKeys: Set<String> = ["lowPass", "highPass", "bandPass", "notch", "equalizer", "distortion", "tube", "chorus", "flanger", "phaser", "tremolo", "vibrato", "wah", "echo", "lowQuality", "robot"]

        public init(lowPass: Filter? = nil, highPass: Filter? = nil, bandPass: Filter? = nil, notch: Filter? = nil,
                    equalizer: ParametricEQ? = nil, distortion: Distortion? = nil, tube: Tube? = nil,
                    chorus: Chorus? = nil, flanger: Flanger? = nil, phaser: Phaser? = nil,
                    tremolo: Tremolo? = nil, vibrato: Vibrato? = nil, wah: Wah? = nil,
                    echo: Echo? = nil, lowQuality: LowQuality? = nil, robot: Robot? = nil) {
            self.lowPass = lowPass; self.highPass = highPass; self.bandPass = bandPass; self.notch = notch
            self.equalizer = equalizer; self.distortion = distortion; self.tube = tube
            self.chorus = chorus; self.flanger = flanger; self.phaser = phaser
            self.tremolo = tremolo; self.vibrato = vibrato; self.wah = wah
            self.echo = echo; self.lowQuality = lowQuality; self.robot = robot
        }

        /// フィルタのスロットを取り出す。
        public func filter(_ kind: FilterKind) -> Filter? {
            switch kind {
            case .lowPass: return lowPass
            case .highPass: return highPass
            case .bandPass: return bandPass
            case .notch: return notch
            }
        }
        public mutating func setFilter(_ kind: FilterKind, _ f: Filter?) {
            switch kind {
            case .lowPass: lowPass = f
            case .highPass: highPass = f
            case .bandPass: bandPass = f
            case .notch: notch = f
            }
        }

        /// 何も入っていない(ファイルに書かない)。
        public var isEmpty: Bool {
            lowPass == nil && highPass == nil && bandPass == nil && notch == nil && equalizer == nil
                && distortion == nil && tube == nil && chorus == nil && flanger == nil && phaser == nil
                && tremolo == nil && vibrato == nil && wah == nil && echo == nil && lowQuality == nil
                && robot == nil && extra.isEmpty
        }

        /// 実際に音を変えるものが 1 つでもある。
        public var isActive: Bool {
            (lowPass?.isActive ?? false) || (highPass?.isActive ?? false) || (bandPass?.isActive ?? false) || (notch?.isActive ?? false)
                || (equalizer?.isActive ?? false) || (distortion?.isActive ?? false) || (tube?.isActive ?? false)
                || (chorus?.isActive ?? false) || (flanger?.isActive ?? false) || (phaser?.isActive ?? false)
                || (tremolo?.isActive ?? false) || (vibrato?.isActive ?? false) || (wah?.isActive ?? false)
                || (echo?.isActive ?? false) || (lowQuality?.isActive ?? false) || (robot?.isActive ?? false)
        }

        /// 音に効く項目だけの文字列(再生用ミックスの鍵に足す)。
        public var cacheToken: String {
            var p: [String] = []
            for kind in FilterKind.allCases {
                if let f = filter(kind), f.isActive { p.append("\(kind.rawValue)=\(f.freqOr(kind.defaultFreq)),\(f.qOr(kind.defaultQ))") }
            }
            if let e = equalizer, e.isActive { p.append("peq=\(e.gains.map { String($0) }.joined(separator: ","))") }
            if let d = distortion, d.isActive { p.append("dist=\(d.driveDb),\(d.mix)") }
            if let t = tube, t.isActive { p.append("tube=\(t.driveDb),\(t.mix)") }
            if let c = chorus, c.isActive { p.append("cho=\(c.rateHz),\(c.depthValue),\(c.mix)") }
            if let f = flanger, f.isActive { p.append("fla=\(f.rateHz),\(f.depthValue),\(f.feedbackValue),\(f.mix)") }
            if let ph = phaser, ph.isActive { p.append("pha=\(ph.rateHz),\(ph.depthValue),\(ph.mix)") }
            if let t = tremolo, t.isActive { p.append("tre=\(t.rateHz),\(t.depthValue)") }
            if let v = vibrato, v.isActive { p.append("vib=\(v.rateHz),\(v.depthMs)") }
            if let w = wah, w.isActive { p.append("wah=\(w.auto),\(w.positionValue),\(w.sensitivityValue)") }
            if let e = echo, e.isActive { p.append("echo=\(e.timeSeconds),\(e.feedbackValue),\(e.mix)") }
            if let q = lowQuality, q.isActive { p.append("lq=\(q.bitsValue),\(q.downsampleValue)") }
            if let r = robot, r.isActive { p.append("rob=\(r.frequencyHz),\(r.mix)") }
            return p.joined(separator: ";")
        }

        public init(from decoder: Decoder) throws {
            let l = Lenient(c: try decoder.container(keyedBy: AnyKey.self), known: Self.knownKeys)
            lowPass = l.value("lowPass"); highPass = l.value("highPass"); bandPass = l.value("bandPass"); notch = l.value("notch")
            equalizer = l.value("equalizer"); distortion = l.value("distortion"); tube = l.value("tube")
            chorus = l.value("chorus"); flanger = l.value("flanger"); phaser = l.value("phaser")
            tremolo = l.value("tremolo"); vibrato = l.value("vibrato"); wah = l.value("wah")
            echo = l.value("echo"); lowQuality = l.value("lowQuality"); robot = l.value("robot")
            extra = l.extra()
            // 読めなかった項目は捨てずに、そのまま書き戻す
            let typed: [String: Bool] = [
                "lowPass": lowPass != nil, "highPass": highPass != nil, "bandPass": bandPass != nil, "notch": notch != nil,
                "equalizer": equalizer != nil, "distortion": distortion != nil, "tube": tube != nil,
                "chorus": chorus != nil, "flanger": flanger != nil, "phaser": phaser != nil,
                "tremolo": tremolo != nil, "vibrato": vibrato != nil, "wah": wah != nil,
                "echo": echo != nil, "lowQuality": lowQuality != nil, "robot": robot != nil,
            ]
            for (key, ok) in typed where !ok {
                if let raw: JSONValue = l.value(key) { extra[key] = raw }
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: AnyKey.self)
            for (k, v) in extra { try c.encode(v, forKey: AnyKey(k)) }
            try c.encodeIfPresent(lowPass, forKey: AnyKey("lowPass"))
            try c.encodeIfPresent(highPass, forKey: AnyKey("highPass"))
            try c.encodeIfPresent(bandPass, forKey: AnyKey("bandPass"))
            try c.encodeIfPresent(notch, forKey: AnyKey("notch"))
            try c.encodeIfPresent(equalizer, forKey: AnyKey("equalizer"))
            try c.encodeIfPresent(distortion, forKey: AnyKey("distortion"))
            try c.encodeIfPresent(tube, forKey: AnyKey("tube"))
            try c.encodeIfPresent(chorus, forKey: AnyKey("chorus"))
            try c.encodeIfPresent(flanger, forKey: AnyKey("flanger"))
            try c.encodeIfPresent(phaser, forKey: AnyKey("phaser"))
            try c.encodeIfPresent(tremolo, forKey: AnyKey("tremolo"))
            try c.encodeIfPresent(vibrato, forKey: AnyKey("vibrato"))
            try c.encodeIfPresent(wah, forKey: AnyKey("wah"))
            try c.encodeIfPresent(echo, forKey: AnyKey("echo"))
            try c.encodeIfPresent(lowQuality, forKey: AnyKey("lowQuality"))
            try c.encodeIfPresent(robot, forKey: AnyKey("robot"))
        }
    }
}
