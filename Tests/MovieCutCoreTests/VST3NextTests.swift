import XCTest
@testable import MovieCutCore

/// VST3 次工程 R5-1 の検証: 単体テストで検証可能な範囲だけを前進させた分。
/// - パラメータ記述モデルと検証/整形(VST3Parameter.swift)
/// - 処理契約の純粋ロジック: バス交渉 / setup 交渉 / ブロック検証 / レイテンシ補償(VST3ProcessingContract.swift)
/// - C++ ブリッジのプロトコル定義と順序契約・前提チェック(VST3Bridge.swift)
/// 実プラグインのロード・実音声処理は範囲外(従来どおり未ロード時はバイパスで音は不変)。
final class VST3NextTests: XCTestCase {

    // MARK: パラメータ記述: 正規化の整形

    func gainParam(stepCount: Int = 0, def: Double = 0.75) -> VST3ParameterDescriptor {
        VST3ParameterDescriptor(id: 100, title: "Gain", shortTitle: "Gn", units: "dB",
                                stepCount: stepCount, defaultNormalizedValue: def,
                                plainRange: -60...6, flags: [.canAutomate])
    }

    func testParameterNormalizedClampsAndFallsBackToDefault() {
        let p = gainParam()
        XCTAssertEqual(p.normalized(0.5), 0.5)
        XCTAssertEqual(p.normalized(1.4), 1)
        XCTAssertEqual(p.normalized(-0.2), 0)
        XCTAssertEqual(p.normalized(.nan), 0.75, "有限でなければ既定値")
        XCTAssertEqual(p.normalized(.infinity), 0.75)
        XCTAssertEqual(gainParam(def: 2).clampedDefault, 1, "不正な既定値でも 0...1 に収まる")
        XCTAssertEqual(gainParam(def: .nan).clampedDefault, 0)
    }

    func testParameterSteppedSnapping() {
        let toggle = gainParam(stepCount: 1, def: 0)
        XCTAssertTrue(toggle.isToggle)
        XCTAssertEqual(toggle.normalized(0.49), 0)
        XCTAssertEqual(toggle.normalized(0.5), 1)
        let four = gainParam(stepCount: 3, def: 0) // 0, 1/3, 2/3, 1
        XCTAssertTrue(four.isStepped)
        XCTAssertEqual(four.normalized(0.4), 1.0 / 3.0, accuracy: 1e-12)
        XCTAssertEqual(four.normalized(0.9), 1)
    }

    func testParameterPlainConversionRoundTrip() {
        let p = gainParam()
        XCTAssertEqual(p.plainValue(forNormalized: 0), -60)
        XCTAssertEqual(p.plainValue(forNormalized: 1), 6)
        XCTAssertEqual(p.plainValue(forNormalized: 0.5), -27)
        XCTAssertEqual(p.normalizedValue(forPlain: -27), 0.5)
        XCTAssertEqual(p.normalizedValue(forPlain: 100), 1, "範囲外は丸める")
        XCTAssertNil(p.normalizedValue(forPlain: .nan))
        // plain 範囲を持たないパラメータは変換を提供しない
        let noRange = VST3ParameterDescriptor(id: 1, title: "X")
        XCTAssertNil(noRange.plainValue(forNormalized: 0.5))
        XCTAssertNil(noRange.normalizedValue(forPlain: 1))
    }

    func testParameterEffectParamSpecConversion() {
        let spec = gainParam().effectParamSpec()
        XCTAssertEqual(spec?.key, "100", "キーはパラメータ ID の文字列")
        XCTAssertEqual(spec?.label, "Gain")
        XCTAssertEqual(spec?.range, 0...1)
        XCTAssertEqual(spec?.defaultValue, 0.75)
        XCTAssertEqual(gainParam(stepCount: 1).effectParamSpec()?.unit, .toggle)
        // 読み取り専用とバイパスは自動生成 UI の編集対象にしない
        XCTAssertNil(VST3ParameterDescriptor(id: 2, title: "Meter", flags: [.isReadOnly]).effectParamSpec())
        XCTAssertNil(VST3ParameterDescriptor(id: 3, title: "Bypass", flags: [.isBypass]).effectParamSpec())
    }

    func testParameterListValidation() {
        let ok = [gainParam(), VST3ParameterDescriptor(id: 101, title: "Mix")]
        XCTAssertEqual(ok.vst3ValidationIssues(), [])
        let bad = [gainParam(), gainParam(),
                   VST3ParameterDescriptor(id: 102, title: " ", defaultNormalizedValue: 1.5),
                   VST3ParameterDescriptor(id: 103, title: "Y", stepCount: -1, plainRange: 5...5)]
        let issues = bad.vst3ValidationIssues()
        XCTAssertTrue(issues.contains { $0.contains("重複") }, "\(issues)")
        XCTAssertTrue(issues.contains { $0.contains("名称が空") })
        XCTAssertTrue(issues.contains { $0.contains("既定値") })
        XCTAssertTrue(issues.contains { $0.contains("stepCount") })
        XCTAssertTrue(issues.contains { $0.contains("表示範囲") })
        XCTAssertEqual(ok.vst3Parameter(storageKey: "101")?.title, "Mix")
        XCTAssertEqual(ok.vst3Parameter(id: 100)?.title, "Gain")
    }

    // MARK: スロット params の照合・整形

    func testSlotParamsSanitizedAgainstDescriptors() {
        let descriptors = [gainParam(),
                           VST3ParameterDescriptor(id: 101, title: "BypassSw", stepCount: 1, defaultNormalizedValue: 0),
                           VST3ParameterDescriptor(id: 102, title: "Meter", flags: [.isReadOnly])]
        var slot = AudioFx.VST3Slot(bundleID: "com.example.testverb",
                                    params: ["100": 1.7, "101": 0.4, "102": 0.5, "999": 0.5, "100x": 0.1])
        let clean = slot.sanitizedParams(against: descriptors)
        XCTAssertEqual(clean, ["100": 1, "101": 0], "範囲丸め・離散スナップ・読専/未知の除去: \(clean)")
        XCTAssertTrue(slot.paramIssues(against: descriptors).count >= 3)
        // 記述が無い(未検出)ときは従来どおり保持する
        slot.params = ["999": 0.5]
        XCTAssertEqual(slot.sanitizedParams(against: []), ["999": 0.5])
        XCTAssertEqual(slot.paramIssues(against: []), [])
        XCTAssertEqual(slot.sanitizedParams(against: descriptors), [:], "記述があるのに未知だけなら空になる")
    }

    func testProviderCarriesParameterDescriptorsWhenProvided() {
        let info = VST3BundleInfo(bundleURL: URL(fileURLWithPath: "/tmp/TestVerb.vst3"),
                                  name: "TestVerb", bundleIdentifier: "com.example.testverb",
                                  architectures: ["arm64"])
        let plain = VST3EffectProvider(plugins: [info])
        XCTAssertEqual(plain.audioEffectDescriptors.first?.params, [], "未提供なら従来どおり空")
        let withParams = VST3EffectProvider(plugins: [info],
                                            parameterDescriptorsByEffectID: [info.audioEffectID: [gainParam()]])
        XCTAssertEqual(withParams.audioEffectDescriptors.first?.params.map { $0.key }, ["100"])
        // 処理器は相変わらずバイパス(パラメータがあっても音は変えない)
        let proc = withParams.makeProcessor(effectID: info.audioEffectID, sampleRate: 48000, values: ["100": 0.5])
        XCTAssertTrue(proc is BypassAudioEffectProcessor)
    }

    // MARK: バス構成の交渉

    func testBusNegotiation() {
        let stereo = VST3BusLayout.movieCutStereo
        XCTAssertEqual(VST3BusLayout.negotiate(requested: stereo, supported: [stereo]), .accepted(stereo))
        XCTAssertEqual(stereo.input.channelCount, 2)
        XCTAssertEqual(VST3SpeakerArrangement.surround51.channelCount, 6)
        XCTAssertEqual(VST3SpeakerArrangement.surround71.channelCount, 8)
        // モノラル入力のみ対応 → 黙って変換せず落とす(理由に区別が付く)
        let monoIn = VST3BusLayout(input: .mono, output: .stereo)
        guard case .rejected(let reason) = VST3BusLayout.negotiate(requested: stereo, supported: [monoIn]) else {
            return XCTFail("落とすべき")
        }
        XCTAssertTrue(reason.contains("入力構成"), reason)
        guard case .rejected = VST3BusLayout.negotiate(requested: stereo, supported: []) else {
            return XCTFail("申告なしは落とす")
        }
    }

    // MARK: setup の交渉

    func testSetupNegotiation() {
        let base = VST3ProcessSetup.movieCutOffline
        XCTAssertEqual(base.mode, .offline)
        XCTAssertEqual(base.sampleRate, 48000)
        // プラグイン上限が小さいときは小さい方へ寄せる
        let capped = base.negotiated(supportedSampleRates: 8000...192000, maxBlockLimit: 1024)
        XCTAssertEqual(try? capped.get().maxSamplesPerBlock, 1024)
        XCTAssertEqual(try? capped.get().sampleRate, 48000, "サンプルレートは勝手に変えない")
        // 対応範囲外のサンプルレートは落とす
        guard case .failure(.sampleRateUnsupported) = base.negotiated(supportedSampleRates: 8000...44100, maxBlockLimit: nil) else {
            return XCTFail("44.1k までしか対応しないプラグインに 48k は渡せない")
        }
        guard case .failure(.invalidSampleRate) = VST3ProcessSetup(mode: .offline, sampleRate: 0, maxSamplesPerBlock: 512)
            .negotiated(supportedSampleRates: nil, maxBlockLimit: nil) else { return XCTFail() }
        guard case .failure(.invalidBlockSize) = VST3ProcessSetup(mode: .offline, sampleRate: 48000, maxSamplesPerBlock: 0)
            .negotiated(supportedSampleRates: nil, maxBlockLimit: nil) else { return XCTFail() }
        // 制約なしなら要求どおり確定
        XCTAssertEqual(try? base.negotiated(supportedSampleRates: nil, maxBlockLimit: nil).get(), base)
    }

    // MARK: ブロック検証と分割計画

    func testProcessBlockValidation() {
        let setup = VST3ProcessSetup.movieCutOffline
        let layout = VST3BusLayout.movieCutStereo
        let ok = VST3ProcessBlockRequest(frames: 512, inputChannels: 2, outputChannels: 2,
                                         changePoints: [VST3ParameterChangePoint(parameterID: 100, sampleOffset: 0, normalizedValue: 0.5),
                                                        VST3ParameterChangePoint(parameterID: 100, sampleOffset: 511, normalizedValue: 1)])
        if case .failure(let e) = ok.validate(setup: setup, layout: layout) { XCTFail("\(e)") }
        // 上限超え
        guard case .failure(.frameCountOutOfRange) = VST3ProcessBlockRequest(frames: 4097, inputChannels: 2, outputChannels: 2)
            .validate(setup: setup, layout: layout) else { return XCTFail() }
        // チャンネル不一致(入力/出力を区別する)
        guard case .failure(.channelCountMismatch(_, _, true)) = VST3ProcessBlockRequest(frames: 64, inputChannels: 1, outputChannels: 2)
            .validate(setup: setup, layout: layout) else { return XCTFail() }
        guard case .failure(.channelCountMismatch(_, _, false)) = VST3ProcessBlockRequest(frames: 64, inputChannels: 2, outputChannels: 6)
            .validate(setup: setup, layout: layout) else { return XCTFail() }
        // 変化点: 範囲外 / 値の範囲外 / 昇順違反
        guard case .failure(.invalidChangePoints) = VST3ProcessBlockRequest(frames: 64, inputChannels: 2, outputChannels: 2,
            changePoints: [VST3ParameterChangePoint(parameterID: 1, sampleOffset: 64, normalizedValue: 0)])
            .validate(setup: setup, layout: layout) else { return XCTFail("オフセット == frames は範囲外") }
        guard case .failure(.invalidChangePoints) = VST3ProcessBlockRequest(frames: 64, inputChannels: 2, outputChannels: 2,
            changePoints: [VST3ParameterChangePoint(parameterID: 1, sampleOffset: 0, normalizedValue: 1.2)])
            .validate(setup: setup, layout: layout) else { return XCTFail() }
        guard case .failure(.invalidChangePoints) = VST3ProcessBlockRequest(frames: 64, inputChannels: 2, outputChannels: 2,
            changePoints: [VST3ParameterChangePoint(parameterID: 1, sampleOffset: 10, normalizedValue: 0),
                           VST3ParameterChangePoint(parameterID: 1, sampleOffset: 5, normalizedValue: 0)])
            .validate(setup: setup, layout: layout) else { return XCTFail("同一パラメータの降順は不可") }
        // 別パラメータ同士の順序は問わない
        if case .failure(let e) = VST3ProcessBlockRequest(frames: 64, inputChannels: 2, outputChannels: 2,
            changePoints: [VST3ParameterChangePoint(parameterID: 1, sampleOffset: 10, normalizedValue: 0),
                           VST3ParameterChangePoint(parameterID: 2, sampleOffset: 5, normalizedValue: 0)])
            .validate(setup: setup, layout: layout) { XCTFail("\(e)") }
    }

    func testBlockPlan() {
        XCTAssertEqual(VST3ProcessBlockRequest.blockPlan(totalFrames: 10000, maxBlock: 4096), [4096, 4096, 1808])
        XCTAssertEqual(VST3ProcessBlockRequest.blockPlan(totalFrames: 4096, maxBlock: 4096), [4096])
        XCTAssertEqual(VST3ProcessBlockRequest.blockPlan(totalFrames: 1, maxBlock: 4096), [1])
        XCTAssertEqual(VST3ProcessBlockRequest.blockPlan(totalFrames: 0, maxBlock: 4096), [])
        XCTAssertEqual(VST3ProcessBlockRequest.blockPlan(totalFrames: 100, maxBlock: 0), [])
    }

    // MARK: レイテンシ/テール補償

    func testLatencyTailCompensation() {
        let lt = VST3LatencyTail(latencyFrames: 128, tailFrames: 4800)
        XCTAssertEqual(lt.headTrimFrames, 128)
        XCTAssertEqual(lt.tailPaddingFrames, 4800)
        XCTAssertEqual(lt.totalInputFrames(forContentFrames: 48000), 52928, "本体 + 遅延の吐き出し分 + テール受け")
        XCTAssertEqual(lt.outputFrames(forContentFrames: 48000), 48000, "補償後の長さは入力と一致する")
        let neg = VST3LatencyTail(latencyFrames: -5, tailFrames: -1)
        XCTAssertEqual(neg.headTrimFrames, 0, "負の申告は 0 に丸める")
        XCTAssertEqual(neg.totalInputFrames(forContentFrames: -10), 0)
        // テールが遅延より短い場合も、先頭を切り落とした後に本体が全部残るだけ流す
        let shortTail = VST3LatencyTail(latencyFrames: 128, tailFrames: 0)
        XCTAssertEqual(shortTail.totalInputFrames(forContentFrames: 1000), 1128)
        XCTAssertEqual(shortTail.totalInputFrames(forContentFrames: 1000) - shortTail.headTrimFrames, 1000)
    }

    func testSampleRateUnsupportedNoteToleratesHugeValues() {
        // 巨大な有限値でも、エラー表示の整数化で落ちない
        let e = VST3ContractError.sampleRateUnsupported(sampleRate: .greatestFiniteMagnitude, supported: 44100...96000)
        XCTAssertTrue(e.userFacingNote.contains("Hz"))
    }

    // MARK: ブリッジプロトコル定義

    func testBridgeDefinitionsAreStable() {
        XCTAssertEqual(VST3Bridge.protocolVersion, 1)
        // opcode は C ヘッダと同順・同値(並びを変えたら両方変える約束の固定)。
        // 10〜14 は R5 キュー3(純正 GUI の土台)で末尾追加したエディタ系。既存 0〜9 は不変。
        XCTAssertEqual(VST3BridgeOpcode.allCases.map { $0.rawValue }, Array(0..<15))
        XCTAssertEqual(VST3BridgeOpcode.processBlock.rawValue, 5)
        // 7 = noEditor は R5 キュー3 で末尾追加(エディタを持たないプラグイン専用)。0〜6 は不変。
        XCTAssertEqual(VST3BridgeStatus.allCases.map { $0.rawValue }, Array(0..<8))
        XCTAssertFalse(VST3BridgeStatus.ok.shouldBypass)
        XCTAssertTrue(VST3BridgeStatus.notImplemented.shouldBypass)
        XCTAssertTrue(VST3BridgeStatus.wrongState.shouldBypass)
    }

    func testBridgeSessionOrdering() {
        typealias S = VST3BridgeSession
        // 正常な流れ: closed → opened → created → configured → active → (dispose) closed
        XCTAssertTrue(S.allows(.openBundle, in: .closed))
        XCTAssertEqual(S.stateAfter(.openBundle, in: .closed), .opened)
        XCTAssertEqual(S.stateAfter(.createProcessor, in: .opened), .created)
        XCTAssertEqual(S.stateAfter(.setupProcessing, in: .created), .configured)
        XCTAssertEqual(S.stateAfter(.setActive, in: .configured), .active)
        XCTAssertEqual(S.stateAfter(.dispose, in: .active), .closed)
        // 順序違反は弾く
        XCTAssertFalse(S.allows(.processBlock, in: .configured), "有効化前の処理は不可")
        XCTAssertNil(S.stateAfter(.processBlock, in: .closed))
        XCTAssertFalse(S.allows(.createProcessor, in: .closed), "開く前に生成は不可")
        XCTAssertFalse(S.allows(.dispose, in: .closed))
        XCTAssertTrue(S.allows(.handshake, in: .closed), "版数照合はいつでも可")
        XCTAssertTrue(S.allows(.getParameterInfos, in: .created))
        XCTAssertFalse(S.allows(.setState, in: .active), "処理中の状態復元は不可(setup 前まで)")
    }

    func testHostPrerequisitesKeepAvailabilityHonest() {
        // 現在の実態は全て未達で、到達状態も未実装のまま(前進はモデル/契約/定義だけ)
        XCTAssertFalse(VST3HostPrerequisites.current.allSatisfied)
        XCTAssertEqual(VST3HostPrerequisites.current.missingDescriptions.count, 4)
        XCTAssertFalse(VST3HostAvailability.current.canProcessAudio)
        let ready = VST3HostPrerequisites(sdkAcquired: true, bridgeIncluded: true,
                                          fixturePluginAvailable: true, distributionDecisionMade: true)
        XCTAssertTrue(ready.allSatisfied)
        XCTAssertEqual(ready.missingDescriptions, [])
    }
}
