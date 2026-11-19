import Foundation

// MARK: - VST3 実ホスト処理器(W6-1: ブリッジバックエンド経由の実処理)
//
// `AudioEffectProcessing` の実装。生成時にブリッジの手順
// (handshake → open → create → [state復元] → setup → activate)を
// `VST3BridgeSession` の順序契約どおりに進め、どこかで失敗したら
// その場で後片付けして「バイパス処理器として振る舞う」状態に落ちる。
// そのため、プラグインが壊れている/見つからない/ブリッジが無い場合でも
// 音声経路は止まらず、音はバイト単位で原音のままになる(安全境界)。
//
// 処理が成立した場合も、ブロックごとに契約検証(`VST3ProcessBlockRequest`)を通し、
// 出力は作業バッファへ受けてから成功したときだけ入力へ戻す。途中ブロックで
// 失敗したら、そのブロック以降はバイパスに切り替える(戻し済みの前ブロックは
// 取り消せない。これは docs に明記する)。
public final class VST3HostProcessor: AudioEffectProcessing {
    public let effectID: String
    /// 実処理が成立しているか(false の間は完全バイパス)。
    public private(set) var isReady: Bool = false
    /// バイパスに落ちた理由(ブリッジの結果コード)。成立していれば nil。
    public private(set) var failureStatus: VST3BridgeStatus?
    /// 状態チャンクの復元に失敗したか(音は続行するので致命ではない)。
    public private(set) var stateRestoreFailed: Bool = false
    /// バイパスしたフレーム数(検証用)。
    public private(set) var bypassedFrames: Int = 0
    /// 実処理したフレーム数。
    public private(set) var processedFrames: Int = 0
    public private(set) var processCalls: Int = 0
    /// プラグイン申告レイテンシ(フレーム。取得できた範囲)。
    public private(set) var latencyFrames: Int = 0
    /// プラグイン申告テール(フレーム)。
    public private(set) var tailFrames: Int = 0
    /// 取得できたパラメータ記述(無ければ空)。
    public private(set) var parameterDescriptors: [VST3ParameterDescriptor] = []

    private var backend: (any VST3BridgeBackend)?
    private var sessionState: VST3BridgeSession.State = .closed
    private let setup: VST3ProcessSetup
    private let initialValues: [String: Double]
    private var pendingInitialChanges: [VST3ParameterChangePoint] = []
    private var scratchL: [Float] = []
    private var scratchR: [Float] = []

    /// 生成と同時に接続を試みる。失敗しても生成自体は成功し、バイパスとして振る舞う
    /// (`isReady == false`、`failureStatus` に理由)。例外は投げない。
    public init(effectID: String, backend: any VST3BridgeBackend, bundlePath: String,
                cid: String? = nil, sampleRate: Double, values: [String: Double] = [:],
                stateData: Data? = nil) {
        self.effectID = effectID
        self.backend = backend
        self.initialValues = values
        // setup は契約ロジックで確定する(48k 前提の既定を、実際のサンプルレートへ差し替える)
        var base = VST3ProcessSetup.movieCutOffline
        base.sampleRate = sampleRate
        self.setup = (try? base.negotiated(supportedSampleRates: nil, maxBlockLimit: nil).get()) ?? base
        connect(bundlePath: bundlePath, cid: cid, stateData: stateData)
    }

    deinit {
        if let backend {
            if sessionState == .active { _ = backend.setActive(false) }
            backend.dispose()
        }
    }

    // MARK: 接続手順(順序契約どおり)

    private func fail(_ status: VST3BridgeStatus) {
        failureStatus = status
        isReady = false
        if let backend {
            if sessionState == .active { _ = backend.setActive(false) }
            if sessionState != .closed { backend.dispose() }
        }
        backend = nil
        sessionState = .closed
    }

    private func perform(_ opcode: VST3BridgeOpcode, _ body: () -> VST3BridgeStatus) -> Bool {
        guard VST3BridgeSession.allows(opcode, in: sessionState) else { fail(.wrongState); return false }
        let s = body()
        guard s == .ok else { fail(s); return false }
        if let next = VST3BridgeSession.stateAfter(opcode, in: sessionState) { sessionState = next }
        return true
    }

    private func connect(bundlePath: String, cid: String?, stateData: Data?) {
        guard let backend else { failureStatus = .notImplemented; return }
        // handshake(順序契約では常時可)
        let hs = backend.handshake()
        guard hs.status == .ok, hs.version == VST3Bridge.protocolVersion else {
            fail(hs.status == .ok ? .internalError : hs.status); return
        }
        guard perform(.openBundle, { backend.openBundle(path: bundlePath) }) else { return }
        guard perform(.createProcessor, { backend.createProcessor(cid: cid) }) else { return }
        // パラメータ記述は取れなくても致命ではない(音は出せる)
        if VST3BridgeSession.allows(.getParameterInfos, in: sessionState) {
            let (s, infos) = backend.parameterInfos()
            if s == .ok, infos.vst3ValidationIssues().isEmpty { parameterDescriptors = infos }
        }
        if let lt = backend.latencyAndTail() { latencyFrames = lt.latency; tailFrames = lt.tail }
        // 状態復元(失敗しても音は続ける)
        if let stateData, !stateData.isEmpty {
            if VST3BridgeSession.allows(.setState, in: sessionState) {
                if backend.setState(stateData) != .ok { stateRestoreFailed = true }
            } else { stateRestoreFailed = true }
        }
        pendingInitialChanges = Self.changePoints(from: initialValues, descriptors: parameterDescriptors)
        guard perform(.setupProcessing, { backend.setupProcessing(self.setup, layout: .movieCutStereo) }) else { return }
        // setActive は引数で遷移先が決まるため、状態機械の代表値ではなくここで直接遷移させる
        guard VST3BridgeSession.allows(.setActive, in: sessionState) else { fail(.wrongState); return }
        let act = backend.setActive(true)
        guard act == .ok else { fail(act); return }
        sessionState = .active
        isReady = true
    }

    /// スロットの params 控え(文字列キー → 正規化値)を、ブロック先頭の変化点にする。
    /// 記述がある場合は整形(範囲・離散段)してから渡し、未知キーは落とす。
    static func changePoints(from values: [String: Double], descriptors: [VST3ParameterDescriptor]) -> [VST3ParameterChangePoint] {
        var points: [VST3ParameterChangePoint] = []
        for key in values.keys.sorted() {
            guard let raw = values[key], raw.isFinite, let id = UInt32(key) else { continue }
            if let d = descriptors.vst3Parameter(id: id) {
                if d.flags.contains(.isReadOnly) { continue }
                points.append(VST3ParameterChangePoint(parameterID: id, sampleOffset: 0, normalizedValue: d.normalized(raw)))
            } else if descriptors.isEmpty {
                points.append(VST3ParameterChangePoint(parameterID: id, sampleOffset: 0, normalizedValue: min(1, max(0, raw))))
            }
        }
        return points
    }

    // MARK: AudioEffectProcessing

    public func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        guard frames > 0 else { return }
        processCalls += 1
        guard isReady, let backend, sessionState == .active else {
            bypassedFrames += frames
            return
        }
        let plan = VST3ProcessBlockRequest.blockPlan(totalFrames: frames, maxBlock: setup.maxSamplesPerBlock)
        var offset = 0
        for blockFrames in plan {
            let request = VST3ProcessBlockRequest(frames: blockFrames, inputChannels: 2, outputChannels: 2,
                                                  changePoints: offset == 0 ? pendingInitialChanges : [])
            if case .failure = request.validate(setup: setup, layout: .movieCutStereo) {
                bypassedFrames += frames - offset
                return  // 形状が契約外なら、このブロック以降は触らない
            }
            if scratchL.count < blockFrames {
                scratchL = [Float](repeating: 0, count: blockFrames)
                scratchR = [Float](repeating: 0, count: blockFrames)
            }
            let (s, latency) = scratchL.withUnsafeMutableBufferPointer { sl in
                scratchR.withUnsafeMutableBufferPointer { sr in
                    backend.processBlock(inputLeft: left + offset, inputRight: right + offset,
                                         outputLeft: sl.baseAddress!, outputRight: sr.baseAddress!,
                                         frames: blockFrames, changes: request.changePoints)
                }
            }
            guard s == .ok else {
                // 失敗したブロックは入力へ戻さない。以降は恒常バイパスへ切り替える。
                bypassedFrames += frames - offset
                fail(s)
                return
            }
            if let latency { latencyFrames = latency }
            // 成功したときだけ作業バッファを入力へ戻す
            for i in 0..<blockFrames {
                left[offset + i] = scratchL[i]
                right[offset + i] = scratchR[i]
            }
            processedFrames += blockFrames
            offset += blockFrames
            if !pendingInitialChanges.isEmpty { pendingInitialChanges = [] }
        }
    }

    public func reset() {
        processedFrames = 0
        bypassedFrames = 0
        processCalls = 0
        pendingInitialChanges = Self.changePoints(from: initialValues, descriptors: parameterDescriptors)
        guard isReady, let backend, sessionState == .active else { return }
        // 非有効化→有効化でプラグイン側の状態(ディレイライン等)を初期化する
        if backend.setActive(false) == .ok {
            sessionState = .configured
            if backend.setActive(true) == .ok { sessionState = .active } else { fail(.internalError) }
        }
    }

    // MARK: 状態とパラメータ(接続中だけ)

    /// 現在の状態チャンクを取り出す(プロジェクト保存用)。取れなければ nil。
    public func captureState() -> Data? {
        guard isReady, let backend, VST3BridgeSession.allows(.getState, in: sessionState) else { return nil }
        let (s, data) = backend.getState()
        return s == .ok ? data : nil
    }

    /// パラメータの現在値を設定する(次回 process の変化点としても積む)。
    @discardableResult
    public func setParameter(id: UInt32, normalizedValue: Double) -> Bool {
        guard isReady, let backend else { return false }
        let value: Double
        if let d = parameterDescriptors.vst3Parameter(id: id) { value = d.normalized(normalizedValue) } else {
            value = min(1, max(0, normalizedValue))
        }
        guard backend.setParameterNormalized(id: id, value: value) == .ok else { return false }
        pendingInitialChanges.append(VST3ParameterChangePoint(parameterID: id, sampleOffset: 0, normalizedValue: value))
        return true
    }
}
