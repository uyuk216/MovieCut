import Foundation

/// 拡張エフェクト(`AudioFx.Extended`)の編集の純粋な計算。既存の `AudioFxEditing` と同じ作法:
/// 変えたときだけ true、既定に戻った項目は nil に戻してファイルに書かない。
public extension AudioFxEditing {
    // MARK: 共通

    /// `extended` を書き換える。空になったら nil に戻す。変化があれば true。
    @discardableResult
    static func editExtended(_ c: inout Clip, _ change: (inout AudioFx.Extended) -> Void) -> Bool {
        edit(&c) { fx in
            var x = fx.extended ?? AudioFx.Extended()
            change(&x)
            fx.extended = x.isEmpty ? nil : x
        }
    }

    /// 拡張エフェクトをまとめて外す(既存エフェクトはそのまま)。
    @discardableResult
    static func clearExtended(_ c: inout Clip) -> Bool { edit(&c) { $0.extended = nil } }

    private static func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
    private static func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
    private static func clamped(_ v: Double, _ r: ClosedRange<Double>) -> Double {
        v.isFinite ? min(max(v, r.lowerBound), r.upperBound) : r.lowerBound
    }

    // MARK: フィルタ(ローパス/ハイパス/バンドパス/ノッチ)

    enum FilterParam: CaseIterable, Sendable {
        case freq, q
        public var label: String { self == .freq ? "周波数（Hz）" : "Q" }
        public var undoName: String { "フィルターの変更" }
    }

    @discardableResult
    static func setFilterEnabled(_ c: inout Clip, kind: AudioFx.FilterKind, _ on: Bool) -> Bool {
        editExtended(&c) { x in
            if on { var f = x.filter(kind) ?? AudioFx.Filter(); f.enabled = true; x.setFilter(kind, f) }
            else if var f = x.filter(kind) { f.enabled = false; x.setFilter(kind, f) }
        }
    }

    @discardableResult
    static func setFilter(_ c: inout Clip, kind: AudioFx.FilterKind, _ p: FilterParam, _ v: Double) -> Bool {
        editExtended(&c) { x in
            var f = x.filter(kind) ?? AudioFx.Filter()
            switch p {
            case .freq: f.freq = clamped(v, AudioFx.Filter.freqRange).rounded()
            case .q: f.q = round2(clamped(v, AudioFx.Filter.qRange))
            }
            x.setFilter(kind, f)
        }
    }

    // MARK: パラメトリック EQ(5 バンド)

    enum ParametricBand: Int, CaseIterable, Sendable {
        case b60 = 0, b250, b1000, b4000, b12000
        public var label: String { "\(Int(AudioFx.ParametricEQ.frequencies[rawValue])) Hz" }
        public func value(of e: AudioFx.ParametricEQ) -> Double { e.gain(rawValue) }
    }

    @discardableResult
    static func setParametricEQ(_ c: inout Clip, band: ParametricBand, db: Double) -> Bool {
        let v = AudioFx.ParametricEQ.clampDb(round1(db))
        return editExtended(&c) { x in
            var e = x.equalizer ?? AudioFx.ParametricEQ()
            switch band {
            case .b60: e.g60 = v == 0 ? nil : v
            case .b250: e.g250 = v == 0 ? nil : v
            case .b1000: e.g1000 = v == 0 ? nil : v
            case .b4000: e.g4000 = v == 0 ? nil : v
            case .b12000: e.g12000 = v == 0 ? nil : v
            }
            x.equalizer = (e.g60 == nil && e.g250 == nil && e.g1000 == nil && e.g4000 == nil && e.g12000 == nil && e.extra.isEmpty) ? nil : e
        }
    }

    @discardableResult
    static func resetParametricEQ(_ c: inout Clip) -> Bool { editExtended(&c) { $0.equalizer = nil } }

    // MARK: ディストーション / チューブ(drive + mix)

    enum DriveParam: CaseIterable, Sendable {
        case drive, mix
        public var label: String { self == .drive ? "ドライブ（dB）" : "ミックス" }
    }

    @discardableResult
    static func setDistortionEnabled(_ c: inout Clip, _ on: Bool) -> Bool {
        editExtended(&c) { x in
            if on { var d = x.distortion ?? AudioFx.Distortion(); d.enabled = true; x.distortion = d }
            else if var d = x.distortion { d.enabled = false; x.distortion = d }
        }
    }

    @discardableResult
    static func setDistortion(_ c: inout Clip, _ p: DriveParam, _ v: Double) -> Bool {
        editExtended(&c) { x in
            var d = x.distortion ?? AudioFx.Distortion()
            switch p {
            case .drive: d.drive = round1(clamped(v, AudioFx.Distortion.driveRange))
            case .mix: d.mixValue = round2(clamped(v, AudioFx.Distortion.mixRange))
            }
            x.distortion = d
        }
    }

    @discardableResult
    static func setTubeEnabled(_ c: inout Clip, _ on: Bool) -> Bool {
        editExtended(&c) { x in
            if on { var d = x.tube ?? AudioFx.Tube(); d.enabled = true; x.tube = d }
            else if var d = x.tube { d.enabled = false; x.tube = d }
        }
    }

    @discardableResult
    static func setTube(_ c: inout Clip, _ p: DriveParam, _ v: Double) -> Bool {
        editExtended(&c) { x in
            var d = x.tube ?? AudioFx.Tube()
            switch p {
            case .drive: d.drive = round1(clamped(v, AudioFx.Tube.driveRange))
            case .mix: d.mixValue = round2(clamped(v, AudioFx.Tube.mixRange))
            }
            x.tube = d
        }
    }

    // MARK: コーラス

    enum ChorusParam: CaseIterable, Sendable {
        case rate, depth, mix
        public var label: String {
            switch self { case .rate: return "速さ（Hz）"; case .depth: return "深さ"; case .mix: return "ミックス" }
        }
        public var range: ClosedRange<Double> {
            switch self {
            case .rate: return AudioFx.Chorus.rateRange
            case .depth: return AudioFx.Chorus.depthRange
            case .mix: return AudioFx.Chorus.mixRange
            }
        }
        public func value(of c: AudioFx.Chorus) -> Double {
            switch self { case .rate: return c.rateHz; case .depth: return c.depthValue; case .mix: return c.mix }
        }
        public var undoName: String { "コーラスの変更" }
    }

    @discardableResult
    static func setChorusEnabled(_ c: inout Clip, _ on: Bool) -> Bool {
        editExtended(&c) { x in
            if on { var d = x.chorus ?? AudioFx.Chorus(); d.enabled = true; x.chorus = d }
            else if var d = x.chorus { d.enabled = false; x.chorus = d }
        }
    }

    @discardableResult
    static func setChorus(_ c: inout Clip, _ p: ChorusParam, _ v: Double) -> Bool {
        let value = round2(clamped(v, p.range))
        return editExtended(&c) { x in
            var d = x.chorus ?? AudioFx.Chorus()
            switch p { case .rate: d.rate = value; case .depth: d.depth = value; case .mix: d.mixValue = value }
            x.chorus = d
        }
    }

    // MARK: フランジャー

    enum FlangerParam: CaseIterable, Sendable {
        case rate, depth, feedback, mix
        public var label: String {
            switch self { case .rate: return "速さ（Hz）"; case .depth: return "深さ"; case .feedback: return "フィードバック"; case .mix: return "ミックス" }
        }
        public var range: ClosedRange<Double> {
            switch self {
            case .rate: return AudioFx.Flanger.rateRange
            case .depth: return AudioFx.Flanger.depthRange
            case .feedback: return AudioFx.Flanger.feedbackRange
            case .mix: return AudioFx.Flanger.mixRange
            }
        }
        public func value(of f: AudioFx.Flanger) -> Double {
            switch self { case .rate: return f.rateHz; case .depth: return f.depthValue; case .feedback: return f.feedbackValue; case .mix: return f.mix }
        }
        public var undoName: String { "フランジャーの変更" }
    }

    @discardableResult
    static func setFlangerEnabled(_ c: inout Clip, _ on: Bool) -> Bool {
        editExtended(&c) { x in
            if on { var d = x.flanger ?? AudioFx.Flanger(); d.enabled = true; x.flanger = d }
            else if var d = x.flanger { d.enabled = false; x.flanger = d }
        }
    }

    @discardableResult
    static func setFlanger(_ c: inout Clip, _ p: FlangerParam, _ v: Double) -> Bool {
        let value = round2(clamped(v, p.range))
        return editExtended(&c) { x in
            var d = x.flanger ?? AudioFx.Flanger()
            switch p { case .rate: d.rate = value; case .depth: d.depth = value; case .feedback: d.feedback = value; case .mix: d.mixValue = value }
            x.flanger = d
        }
    }

    // MARK: フェイザー

    enum PhaserParam: CaseIterable, Sendable {
        case rate, depth, mix
        public var label: String {
            switch self { case .rate: return "速さ（Hz）"; case .depth: return "深さ"; case .mix: return "ミックス" }
        }
        public var range: ClosedRange<Double> {
            switch self {
            case .rate: return AudioFx.Phaser.rateRange
            case .depth: return AudioFx.Phaser.depthRange
            case .mix: return AudioFx.Phaser.mixRange
            }
        }
        public func value(of p: AudioFx.Phaser) -> Double {
            switch self { case .rate: return p.rateHz; case .depth: return p.depthValue; case .mix: return p.mix }
        }
        public var undoName: String { "フェイザーの変更" }
    }

    @discardableResult
    static func setPhaserEnabled(_ c: inout Clip, _ on: Bool) -> Bool {
        editExtended(&c) { x in
            if on { var d = x.phaser ?? AudioFx.Phaser(); d.enabled = true; x.phaser = d }
            else if var d = x.phaser { d.enabled = false; x.phaser = d }
        }
    }

    @discardableResult
    static func setPhaser(_ c: inout Clip, _ p: PhaserParam, _ v: Double) -> Bool {
        let value = round2(clamped(v, p.range))
        return editExtended(&c) { x in
            var d = x.phaser ?? AudioFx.Phaser()
            switch p { case .rate: d.rate = value; case .depth: d.depth = value; case .mix: d.mixValue = value }
            x.phaser = d
        }
    }

    // MARK: トレモロ / ビブラート

    enum TremoloParam: CaseIterable, Sendable {
        case rate, depth
        public var label: String { self == .rate ? "速さ（Hz）" : "深さ" }
        public var range: ClosedRange<Double> { self == .rate ? AudioFx.Tremolo.rateRange : AudioFx.Tremolo.depthRange }
        public func value(of t: AudioFx.Tremolo) -> Double { self == .rate ? t.rateHz : t.depthValue }
        public var undoName: String { "トレモロの変更" }
    }

    @discardableResult
    static func setTremoloEnabled(_ c: inout Clip, _ on: Bool) -> Bool {
        editExtended(&c) { x in
            if on { var d = x.tremolo ?? AudioFx.Tremolo(); d.enabled = true; x.tremolo = d }
            else if var d = x.tremolo { d.enabled = false; x.tremolo = d }
        }
    }

    @discardableResult
    static func setTremolo(_ c: inout Clip, _ p: TremoloParam, _ v: Double) -> Bool {
        let value = round2(clamped(v, p.range))
        return editExtended(&c) { x in
            var d = x.tremolo ?? AudioFx.Tremolo()
            switch p { case .rate: d.rate = value; case .depth: d.depth = value }
            x.tremolo = d
        }
    }

    enum VibratoParam: CaseIterable, Sendable {
        case rate, depth
        public var label: String { self == .rate ? "速さ（Hz）" : "深さ（ms）" }
        public var range: ClosedRange<Double> { self == .rate ? AudioFx.Vibrato.rateRange : AudioFx.Vibrato.depthRange }
        public func value(of t: AudioFx.Vibrato) -> Double { self == .rate ? t.rateHz : t.depthMs }
        public var undoName: String { "ビブラートの変更" }
    }

    @discardableResult
    static func setVibratoEnabled(_ c: inout Clip, _ on: Bool) -> Bool {
        editExtended(&c) { x in
            if on { var d = x.vibrato ?? AudioFx.Vibrato(); d.enabled = true; x.vibrato = d }
            else if var d = x.vibrato { d.enabled = false; x.vibrato = d }
        }
    }

    @discardableResult
    static func setVibrato(_ c: inout Clip, _ p: VibratoParam, _ v: Double) -> Bool {
        let value = round2(clamped(v, p.range))
        return editExtended(&c) { x in
            var d = x.vibrato ?? AudioFx.Vibrato()
            switch p { case .rate: d.rate = value; case .depth: d.depth = value }
            x.vibrato = d
        }
    }

    // MARK: ワウ / オートワウ

    enum WahParam: CaseIterable, Sendable {
        case position, sensitivity
        public var label: String { self == .position ? "開き具合" : "感度" }
        public var range: ClosedRange<Double> { self == .position ? AudioFx.Wah.positionRange : AudioFx.Wah.sensitivityRange }
        public func value(of w: AudioFx.Wah) -> Double { self == .position ? w.positionValue : w.sensitivityValue }
        public var undoName: String { "ワウの変更" }
    }

    @discardableResult
    static func setWahEnabled(_ c: inout Clip, _ on: Bool) -> Bool {
        editExtended(&c) { x in
            if on { var d = x.wah ?? AudioFx.Wah(); d.enabled = true; x.wah = d }
            else if var d = x.wah { d.enabled = false; x.wah = d }
        }
    }

    @discardableResult
    static func setWahAuto(_ c: inout Clip, _ on: Bool) -> Bool {
        editExtended(&c) { x in var d = x.wah ?? AudioFx.Wah(); d.auto = on; x.wah = d }
    }

    @discardableResult
    static func setWah(_ c: inout Clip, _ p: WahParam, _ v: Double) -> Bool {
        let value = round2(clamped(v, p.range))
        return editExtended(&c) { x in
            var d = x.wah ?? AudioFx.Wah()
            switch p { case .position: d.position = value; case .sensitivity: d.sensitivity = value }
            x.wah = d
        }
    }

    // MARK: エコー

    enum EchoParam: CaseIterable, Sendable {
        case time, feedback, mix
        public var label: String {
            switch self { case .time: return "間隔（秒）"; case .feedback: return "繰り返し"; case .mix: return "ミックス" }
        }
        public var range: ClosedRange<Double> {
            switch self {
            case .time: return AudioFx.Echo.timeRange
            case .feedback: return AudioFx.Echo.feedbackRange
            case .mix: return AudioFx.Echo.mixRange
            }
        }
        public func value(of e: AudioFx.Echo) -> Double {
            switch self { case .time: return e.timeSeconds; case .feedback: return e.feedbackValue; case .mix: return e.mix }
        }
        public var undoName: String { "エコーの変更" }
    }

    @discardableResult
    static func setEchoEnabled(_ c: inout Clip, _ on: Bool) -> Bool {
        editExtended(&c) { x in
            if on { var d = x.echo ?? AudioFx.Echo(); d.enabled = true; x.echo = d }
            else if var d = x.echo { d.enabled = false; x.echo = d }
        }
    }

    @discardableResult
    static func setEcho(_ c: inout Clip, _ p: EchoParam, _ v: Double) -> Bool {
        let value = round2(clamped(v, p.range))
        return editExtended(&c) { x in
            var d = x.echo ?? AudioFx.Echo()
            switch p { case .time: d.time = value; case .feedback: d.feedback = value; case .mix: d.mixValue = value }
            x.echo = d
        }
    }

    // MARK: 低音質化

    enum LowQualityParam: CaseIterable, Sendable {
        case bits, downsample
        public var label: String { self == .bits ? "ビット数" : "ダウンサンプル（÷）" }
        public var range: ClosedRange<Double> { self == .bits ? AudioFx.LowQuality.bitsRange : AudioFx.LowQuality.downsampleRange }
        public func value(of q: AudioFx.LowQuality) -> Double { self == .bits ? Double(q.bitsValue) : Double(q.downsampleValue) }
        public var undoName: String { "低音質化の変更" }
    }

    @discardableResult
    static func setLowQualityEnabled(_ c: inout Clip, _ on: Bool) -> Bool {
        editExtended(&c) { x in
            if on { var d = x.lowQuality ?? AudioFx.LowQuality(); d.enabled = true; x.lowQuality = d }
            else if var d = x.lowQuality { d.enabled = false; x.lowQuality = d }
        }
    }

    @discardableResult
    static func setLowQuality(_ c: inout Clip, _ p: LowQualityParam, _ v: Double) -> Bool {
        let value = clamped(v, p.range).rounded()
        return editExtended(&c) { x in
            var d = x.lowQuality ?? AudioFx.LowQuality()
            switch p { case .bits: d.bits = value; case .downsample: d.downsample = value }
            x.lowQuality = d
        }
    }

    // MARK: ロボット化

    enum RobotParam: CaseIterable, Sendable {
        case frequency, mix
        public var label: String { self == .frequency ? "搬送波（Hz）" : "ミックス" }
        public var range: ClosedRange<Double> { self == .frequency ? AudioFx.Robot.frequencyRange : AudioFx.Robot.mixRange }
        public func value(of r: AudioFx.Robot) -> Double { self == .frequency ? r.frequencyHz : r.mix }
        public var undoName: String { "ロボット化の変更" }
    }

    @discardableResult
    static func setRobotEnabled(_ c: inout Clip, _ on: Bool) -> Bool {
        editExtended(&c) { x in
            if on { var d = x.robot ?? AudioFx.Robot(); d.enabled = true; x.robot = d }
            else if var d = x.robot { d.enabled = false; x.robot = d }
        }
    }

    @discardableResult
    static func setRobot(_ c: inout Clip, _ p: RobotParam, _ v: Double) -> Bool {
        let value = p == .frequency ? clamped(v, p.range).rounded() : round2(clamped(v, p.range))
        return editExtended(&c) { x in
            var d = x.robot ?? AudioFx.Robot()
            switch p { case .frequency: d.frequency = value; case .mix: d.mixValue = value }
            x.robot = d
        }
    }
}
