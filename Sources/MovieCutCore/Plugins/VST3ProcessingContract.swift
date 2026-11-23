import Foundation

// MARK: - VST3 オーディオ処理の契約(R5-1: 純粋ロジック化)
//
// 実ホスト(C++ ブリッジ)が将来 `IAudioProcessor` と交渉する内容を、SDK 非依存の
// 純粋ロジックとして先に固定する:
// - バス構成(スピーカー配置)の表現と、ホスト要求との突き合わせ(交渉)
// - setupProcessing の交渉(サンプルレート / 最大ブロック長 / 処理モード)
// - process の 1 ブロック分の入力検証(バッファ形状・パラメータ変化点)
// - レイテンシ/テールの補償計算(オフライン書き出しの長さ決め)
//
// すべて値の計算だけで、音声バッファには触らない。実処理は範囲外(docs 参照)。
// MovieCut 側の前提: ミックスは 48 kHz ステレオ Float32、オフライン・決定的
// (`AudioMixer` / `AudioFxChain`)。契約の既定もそれに合わせる。

// MARK: バス構成

/// スピーカー配置(VST3 の Speaker Arrangement の、MovieCut が扱う範囲のモデル)。
public enum VST3SpeakerArrangement: String, Equatable, Sendable, CaseIterable {
    case empty      // バス無効(サイドチェイン無し等で使う)
    case mono
    case stereo
    case surround51 // 5.1: L R C LFE Ls Rs
    case surround71 // 7.1: L R C LFE Ls Rs Lc Rc(映画式の並びは実ホストで対応表を持つ)

    public var channelCount: Int {
        switch self {
        case .empty: return 0
        case .mono: return 1
        case .stereo: return 2
        case .surround51: return 6
        case .surround71: return 8
        }
    }
}

/// 入出力バス構成の組(メイン入出力のみ。補助バスは実ホスト工程で拡張する)。
public struct VST3BusLayout: Equatable, Sendable {
    public var input: VST3SpeakerArrangement
    public var output: VST3SpeakerArrangement
    public init(input: VST3SpeakerArrangement, output: VST3SpeakerArrangement) {
        self.input = input; self.output = output
    }
    /// MovieCut のミックスが要求する構成(ステレオ入出力)。
    public static let movieCutStereo = VST3BusLayout(input: .stereo, output: .stereo)
}

/// バス構成の交渉結果。
public enum VST3BusNegotiation: Equatable, Sendable {
    /// この構成で確定。
    case accepted(VST3BusLayout)
    /// 対応構成が無い(理由付き)。呼び出し側はバイパスに落とす。
    case rejected(reason: String)
}

public extension VST3BusLayout {
    /// プラグインが対応する構成一覧から、ホスト要求に合うものを選ぶ。
    /// 完全一致を最優先し、次点として「入力がモノラルでもステレオ出力できる」等は
    /// 選ばない(音が変わる変換を黙ってしない。モノラル→ステレオは別途明示が必要)。
    static func negotiate(requested: VST3BusLayout, supported: [VST3BusLayout]) -> VST3BusNegotiation {
        if supported.contains(requested) { return .accepted(requested) }
        if supported.isEmpty { return .rejected(reason: "プラグインがバス構成を 1 つも申告していない") }
        // 出力だけでも要求に合う構成があれば、その旨を理由に含めて落とす(将来の変換検討用に区別する)
        if supported.contains(where: { $0.output == requested.output }) {
            return .rejected(reason: "出力は一致するが入力構成が合わない(要求: \(requested.input.rawValue)、対応: \(supported.map { $0.input.rawValue }.joined(separator: ",")))")
        }
        return .rejected(reason: "要求する入出力構成 \(requested.input.rawValue)→\(requested.output.rawValue) に対応していない")
    }
}

// MARK: setup(処理開始前の交渉)

/// 処理モード。MovieCut はオフライン書き出しが本命(VST3 の kOffline)。
public enum VST3ProcessingMode: String, Equatable, Sendable {
    case realtime
    case prefetch
    case offline
}

/// setupProcessing の交渉入力と確定結果。
public struct VST3ProcessSetup: Equatable, Sendable {
    public var mode: VST3ProcessingMode
    /// サンプルレート(Hz)。MovieCut は 48000 固定。
    public var sampleRate: Double
    /// 1 ブロックの最大フレーム数。実ホストはこの範囲内でブロックを切る。
    public var maxSamplesPerBlock: Int
    /// サンプルの型は Float32 のみ対応する(MovieCut の内部形式)。
    public var usesFloat32: Bool { true }

    /// MovieCut のオフライン処理の既定: 48 kHz / オフライン / 最大 4096 フレーム。
    public static let movieCutOffline = VST3ProcessSetup(mode: .offline, sampleRate: 48000, maxSamplesPerBlock: 4096)

    public init(mode: VST3ProcessingMode, sampleRate: Double, maxSamplesPerBlock: Int) {
        self.mode = mode; self.sampleRate = sampleRate; self.maxSamplesPerBlock = maxSamplesPerBlock
    }

    /// プラグイン側の制約(対応サンプルレート範囲・最大ブロック長の上限)と突き合わせ、
    /// 確定できる setup を返す。確定できなければ理由を返す。
    /// - サンプルレートは要求値をそのまま使う(勝手なリサンプルはしない)
    /// - 最大ブロック長は、プラグイン上限があれば小さい方へ寄せる(大きくはしない)
    public func negotiated(supportedSampleRates: ClosedRange<Double>?,
                           maxBlockLimit: Int?) -> Result<VST3ProcessSetup, VST3ContractError> {
        guard sampleRate.isFinite, sampleRate > 0 else {
            return .failure(.invalidSampleRate(sampleRate))
        }
        if let supportedSampleRates, !supportedSampleRates.contains(sampleRate) {
            return .failure(.sampleRateUnsupported(sampleRate: sampleRate, supported: supportedSampleRates))
        }
        guard maxSamplesPerBlock > 0 else { return .failure(.invalidBlockSize(maxSamplesPerBlock)) }
        var block = maxSamplesPerBlock
        if let maxBlockLimit {
            guard maxBlockLimit > 0 else { return .failure(.invalidBlockSize(maxBlockLimit)) }
            block = min(block, maxBlockLimit)
        }
        return .success(VST3ProcessSetup(mode: mode, sampleRate: sampleRate, maxSamplesPerBlock: block))
    }
}

/// 契約上の失敗(実ホストはこれを tresult 等へ写す。呼び出し側はバイパスに落とす)。
public enum VST3ContractError: Error, Equatable, Sendable {
    case invalidSampleRate(Double)
    case sampleRateUnsupported(sampleRate: Double, supported: ClosedRange<Double>)
    case invalidBlockSize(Int)
    case frameCountOutOfRange(frames: Int, max: Int)
    case channelCountMismatch(expected: Int, actual: Int, isInput: Bool)
    case invalidChangePoints(reason: String)

    /// Hz 表示用の安全な整数化(非有限・巨大な値でも整数変換で落ちない)。
    private static func hz(_ v: Double) -> Int { v.isFinite ? Int(min(max(v, 0), 9_000_000_000_000_000)) : 0 }

    public var userFacingNote: String {
        switch self {
        case .invalidSampleRate: return "サンプルレートが不正なため VST3 処理を確定できません"
        case .sampleRateUnsupported(let sr, let range): return "サンプルレート \(Self.hz(sr)) Hz はプラグインの対応範囲 \(Self.hz(range.lowerBound))〜\(Self.hz(range.upperBound)) Hz の外です"
        case .invalidBlockSize: return "ブロック長が不正なため VST3 処理を確定できません"
        case .frameCountOutOfRange(let f, let m): return "ブロックのフレーム数 \(f) が上限 \(m) を超えています"
        case .channelCountMismatch(let e, let a, let isInput): return "\(isInput ? "入力" : "出力")のチャンネル数が合いません(期待 \(e) / 実際 \(a))"
        case .invalidChangePoints(let r): return "パラメータ変化点が不正です: \(r)"
        }
    }
}

// MARK: process(1 ブロックの検証)

/// パラメータ変化点 1 件(`IParamValueQueue` の 1 点のモデル)。
public struct VST3ParameterChangePoint: Equatable, Sendable {
    public var parameterID: UInt32
    /// ブロック先頭からのオフセット(フレーム)。
    public var sampleOffset: Int
    /// 正規化値(0...1)。
    public var normalizedValue: Double
    public init(parameterID: UInt32, sampleOffset: Int, normalizedValue: Double) {
        self.parameterID = parameterID; self.sampleOffset = sampleOffset; self.normalizedValue = normalizedValue
    }
}

/// 1 ブロック分の処理要求の「形状」だけを表す値(バッファ実体は持たない)。
public struct VST3ProcessBlockRequest: Equatable, Sendable {
    public var frames: Int
    public var inputChannels: Int
    public var outputChannels: Int
    public var changePoints: [VST3ParameterChangePoint]
    public init(frames: Int, inputChannels: Int, outputChannels: Int, changePoints: [VST3ParameterChangePoint] = []) {
        self.frames = frames; self.inputChannels = inputChannels
        self.outputChannels = outputChannels; self.changePoints = changePoints
    }

    /// setup とバス構成に対して、このブロックが契約どおりかを検証する。
    public func validate(setup: VST3ProcessSetup, layout: VST3BusLayout) -> Result<Void, VST3ContractError> {
        guard frames > 0, frames <= setup.maxSamplesPerBlock else {
            return .failure(.frameCountOutOfRange(frames: frames, max: setup.maxSamplesPerBlock))
        }
        guard inputChannels == layout.input.channelCount else {
            return .failure(.channelCountMismatch(expected: layout.input.channelCount, actual: inputChannels, isInput: true))
        }
        guard outputChannels == layout.output.channelCount else {
            return .failure(.channelCountMismatch(expected: layout.output.channelCount, actual: outputChannels, isInput: false))
        }
        // 変化点: 同一パラメータ内ではオフセット昇順、範囲はブロック内、値は 0...1
        var lastOffsetByParam: [UInt32: Int] = [:]
        for point in changePoints {
            guard point.sampleOffset >= 0, point.sampleOffset < frames else {
                return .failure(.invalidChangePoints(reason: "オフセット \(point.sampleOffset) がブロック(0..<\(frames))の外"))
            }
            guard point.normalizedValue.isFinite, (0...1).contains(point.normalizedValue) else {
                return .failure(.invalidChangePoints(reason: "パラメータ \(point.parameterID) の値が 0...1 の外"))
            }
            if let last = lastOffsetByParam[point.parameterID], point.sampleOffset < last {
                return .failure(.invalidChangePoints(reason: "パラメータ \(point.parameterID) の変化点が昇順でない"))
            }
            lastOffsetByParam[point.parameterID] = point.sampleOffset
        }
        return .success(())
    }

    /// 長い区間を setup の最大ブロック長で割る計画(オフライン処理のブロック分割)。
    /// 末尾は端数ブロックになる。0 以下は空。
    public static func blockPlan(totalFrames: Int, maxBlock: Int) -> [Int] {
        guard totalFrames > 0, maxBlock > 0 else { return [] }
        var out: [Int] = []
        var rest = totalFrames
        while rest > maxBlock { out.append(maxBlock); rest -= maxBlock }
        if rest > 0 { out.append(rest) }
        return out
    }
}

// MARK: レイテンシ / テールの補償(オフライン書き出し)

/// プラグインのレイテンシとテールから、オフライン書き出しで必要な補償を計算する。
public struct VST3LatencyTail: Equatable, Sendable {
    /// プラグインが申告するレイテンシ(フレーム)。負値は 0 として扱う。
    public var latencyFrames: Int
    /// テール(余韻)の長さ(フレーム)。申告なし/無限大の扱いは `hasTail` で区別する。
    public var tailFrames: Int
    public init(latencyFrames: Int, tailFrames: Int) {
        self.latencyFrames = max(0, latencyFrames); self.tailFrames = max(0, tailFrames)
    }

    /// 書き出しの先頭で切り落とすべきフレーム数(= レイテンシ補償)。
    public var headTrimFrames: Int { latencyFrames }
    /// 入力の末尾に、余韻を受け取るために足すべき無音フレーム数。
    public var tailPaddingFrames: Int { tailFrames }
    /// 入力 N フレームに対して、プラグインへ流す総フレーム数(本体 + テール受け + 遅延の吐き出し分)。
    /// 遅延のある処理器は、先頭の遅延分を切り落とすと末尾がその分だけ足りなくなる。
    /// テールが遅延より短い場合でも本体を取り切れるよう、遅延分も流す。
    public func totalInputFrames(forContentFrames content: Int) -> Int {
        max(0, content) + latencyFrames + tailPaddingFrames
    }
    /// 補償後に最終成果物へ残るフレーム数(入力と同じ長さに戻るのが原則)。
    public func outputFrames(forContentFrames content: Int) -> Int { max(0, content) }
}
