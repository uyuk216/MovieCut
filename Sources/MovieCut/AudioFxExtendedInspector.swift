import SwiftUI
import MovieCutCore

/// インスペクタ「音声」の拡張エフェクト節(フィルタ・5バンドEQ・歪み・モジュレーション・ワウ・エコー・低音質化・ロボット化)。
/// 操作の作法は `AudioFxPanel` と同じ: スライダーのドラッグは 1 回の Undo、トグルは 1 操作 = 1 回。
struct AudioFxExtendedPanel: View {
    @ObservedObject var model: ProjectModel
    let clipId: String
    var forceExpanded = false

    @State private var open: [String: Bool] = [:]

    fileprivate var clip: Clip? { model.clip(clipId) }
    private var fx: AudioFx.Extended? { clip?.audioFx?.extended }

    private static func db(_ v: Double) -> String { (v > 0 ? "+" : v < 0 ? "−" : "") + String(format: "%.1f dB", abs(v)) }
    private static func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

    private func expanded(_ key: String, active: Bool) -> Binding<Bool> {
        Binding(get: { open[key] ?? (forceExpanded || active) }, set: { open[key] = $0 })
    }

    private func fxSlider(_ label: String, value: Double, range: ClosedRange<Double>, step: Double, format: @escaping (Double) -> String,
                          undo: String, apply: @escaping (inout Clip, Double) -> Void) -> some View {
        LiveSlider(label: label, value: value, range: range, step: step, format: format,
                   begin: { model.beginGesture() },
                   change: { v in model.liveAudioFx({ apply(&$0, v) }, name: undo, clipId: clipId) },
                   end: { model.commitGesture(undo) })
    }

    private func onOff(_ isOn: Bool, undo: String, apply: @escaping (inout Clip, Bool) -> Void) -> Binding<Bool> {
        Binding(get: { isOn }, set: { v in model.setAudioFx({ apply(&$0, v) }, name: undo, clipId: clipId) })
    }

    var body: some View {
        if let c = clip, AudioFxEditing.supports(c) {
            VStack(alignment: .leading, spacing: 8) {
                filterGroup(c)
                parametricEQGroup(c)
                distortionGroup(c)
                tubeGroup(c)
                chorusGroup(c)
                flangerGroup(c)
                phaserGroup(c)
                tremoloGroup(c)
                vibratoGroup(c)
                wahGroup(c)
                echoGroup(c)
                lowQualityGroup(c)
                robotGroup(c)
                if fx != nil {
                    HStack {
                        Spacer()
                        Button("拡張エフェクトをすべて外す") {
                            model.setAudioFx({ _ = AudioFxEditing.clearExtended(&$0) }, name: "拡張エフェクトを外す", clipId: clipId)
                        }
                    }
                }
            }
            .controlSize(.small)
        }
    }

    // MARK: フィルタ

    @ViewBuilder private func filterGroup(_ c: Clip) -> some View {
        let anyActive = AudioFx.FilterKind.allCases.contains { fx?.filter($0)?.isActive ?? false }
        DisclosureGroup(isExpanded: expanded("filter", active: anyActive)) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(AudioFx.FilterKind.allCases, id: \.self) { kind in
                    let f = fx?.filter(kind)
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("\(kind.label)を使う", isOn: onOff(f?.enabled ?? false, undo: "フィルターの切り替え") {
                            _ = AudioFxEditing.setFilterEnabled(&$0, kind: kind, $1)
                        })
                        .toggleStyle(.checkbox)
                        if f != nil {
                            fxSlider("周波数", value: f!.freqOr(kind.defaultFreq), range: AudioFx.Filter.freqRange, step: 10,
                                     format: { "\(Int($0.rounded())) Hz" }, undo: AudioFxEditing.FilterParam.freq.undoName) {
                                _ = AudioFxEditing.setFilter(&$0, kind: kind, .freq, $1)
                            }
                            fxSlider("Q", value: f!.qOr(kind.defaultQ), range: AudioFx.Filter.qRange, step: 0.1,
                                     format: { String(format: "%.1f", $0) }, undo: AudioFxEditing.FilterParam.q.undoName) {
                                _ = AudioFxEditing.setFilter(&$0, kind: kind, .q, $1)
                            }
                        }
                    }
                    .opacity((f?.enabled ?? false) ? 1 : 0.6)
                }
                Text("ハイパス→ローパス→バンドパス→ノッチの順にかかります。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        } label: {
            Text("フィルター").font(.system(size: 12, weight: .semibold)).foregroundStyle(anyActive ? Color.primary : Color.secondary)
        }
    }

    // MARK: パラメトリック EQ

    @ViewBuilder private func parametricEQGroup(_ c: Clip) -> some View {
        let eq = fx?.equalizer ?? AudioFx.ParametricEQ()
        DisclosureGroup(isExpanded: expanded("peq", active: eq.isActive)) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(AudioFxEditing.ParametricBand.allCases, id: \.self) { band in
                    fxSlider(band.label, value: band.value(of: eq), range: AudioFx.ParametricEQ.range, step: 0.5, format: Self.db, undo: "イコライザー（5バンド）の変更") {
                        _ = AudioFxEditing.setParametricEQ(&$0, band: band, db: $1)
                    }
                }
                HStack {
                    Spacer()
                    Button("リセット") { model.setAudioFx({ _ = AudioFxEditing.resetParametricEQ(&$0) }, name: "イコライザー（5バンド）のリセット", clipId: clipId) }
                        .disabled(!eq.isActive)
                }
            }
            .padding(.top, 4)
        } label: {
            Text("イコライザー（5バンド）").font(.system(size: 12, weight: .semibold)).foregroundStyle(eq.isActive ? Color.primary : Color.secondary)
        }
    }

    // MARK: 歪み 2 種

    @ViewBuilder private func distortionGroup(_ c: Clip) -> some View {
        let d = fx?.distortion
        let on = d?.isActive ?? false
        DisclosureGroup(isExpanded: expanded("dist", active: on)) {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("ディストーションを使う", isOn: onOff(d?.enabled ?? false, undo: "ディストーションの切り替え") {
                    _ = AudioFxEditing.setDistortionEnabled(&$0, $1)
                }).toggleStyle(.checkbox)
                let k = d ?? AudioFx.Distortion()
                VStack(alignment: .leading, spacing: 6) {
                    fxSlider("ドライブ", value: k.driveDb, range: AudioFx.Distortion.driveRange, step: 0.5, format: Self.db, undo: "ディストーションの変更") {
                        _ = AudioFxEditing.setDistortion(&$0, .drive, $1)
                    }
                    fxSlider("ミックス", value: k.mix, range: AudioFx.Distortion.mixRange, step: 0.01, format: Self.pct, undo: "ディストーションの変更") {
                        _ = AudioFxEditing.setDistortion(&$0, .mix, $1)
                    }
                }.opacity((d?.enabled ?? false) ? 1 : 0.45)
            }
            .padding(.top, 4)
        } label: {
            Text("ディストーション").font(.system(size: 12, weight: .semibold)).foregroundStyle(on ? Color.primary : Color.secondary)
        }
    }

    @ViewBuilder private func tubeGroup(_ c: Clip) -> some View {
        let d = fx?.tube
        let on = d?.isActive ?? false
        DisclosureGroup(isExpanded: expanded("tube", active: on)) {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("チューブを使う", isOn: onOff(d?.enabled ?? false, undo: "チューブの切り替え") {
                    _ = AudioFxEditing.setTubeEnabled(&$0, $1)
                }).toggleStyle(.checkbox)
                let k = d ?? AudioFx.Tube()
                VStack(alignment: .leading, spacing: 6) {
                    fxSlider("ドライブ", value: k.driveDb, range: AudioFx.Tube.driveRange, step: 0.5, format: Self.db, undo: "チューブの変更") {
                        _ = AudioFxEditing.setTube(&$0, .drive, $1)
                    }
                    fxSlider("ミックス", value: k.mix, range: AudioFx.Tube.mixRange, step: 0.01, format: Self.pct, undo: "チューブの変更") {
                        _ = AudioFxEditing.setTube(&$0, .mix, $1)
                    }
                    Text("真空管風の柔らかい歪み（近似）です。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.opacity((d?.enabled ?? false) ? 1 : 0.45)
            }
            .padding(.top, 4)
        } label: {
            Text("チューブ").font(.system(size: 12, weight: .semibold)).foregroundStyle(on ? Color.primary : Color.secondary)
        }
    }

    // MARK: モジュレーション

    @ViewBuilder private func chorusGroup(_ c: Clip) -> some View {
        let d = fx?.chorus
        let on = d?.isActive ?? false
        DisclosureGroup(isExpanded: expanded("chorus", active: on)) {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("コーラスを使う", isOn: onOff(d?.enabled ?? false, undo: "コーラスの切り替え") {
                    _ = AudioFxEditing.setChorusEnabled(&$0, $1)
                }).toggleStyle(.checkbox)
                let k = d ?? AudioFx.Chorus()
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(AudioFxEditing.ChorusParam.allCases, id: \.self) { p in
                        fxSlider(p.label, value: p.value(of: k), range: p.range, step: 0.05,
                                 format: { p == .rate ? String(format: "%.2f Hz", $0) : Self.pct($0) }, undo: p.undoName) {
                            _ = AudioFxEditing.setChorus(&$0, p, $1)
                        }
                    }
                }.opacity((d?.enabled ?? false) ? 1 : 0.45)
            }
            .padding(.top, 4)
        } label: {
            Text("コーラス").font(.system(size: 12, weight: .semibold)).foregroundStyle(on ? Color.primary : Color.secondary)
        }
    }

    @ViewBuilder private func flangerGroup(_ c: Clip) -> some View {
        let d = fx?.flanger
        let on = d?.isActive ?? false
        DisclosureGroup(isExpanded: expanded("flanger", active: on)) {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("フランジャーを使う", isOn: onOff(d?.enabled ?? false, undo: "フランジャーの切り替え") {
                    _ = AudioFxEditing.setFlangerEnabled(&$0, $1)
                }).toggleStyle(.checkbox)
                let k = d ?? AudioFx.Flanger()
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(AudioFxEditing.FlangerParam.allCases, id: \.self) { p in
                        fxSlider(p.label, value: p.value(of: k), range: p.range, step: 0.05,
                                 format: { p == .rate ? String(format: "%.2f Hz", $0) : Self.pct($0) }, undo: p.undoName) {
                            _ = AudioFxEditing.setFlanger(&$0, p, $1)
                        }
                    }
                }.opacity((d?.enabled ?? false) ? 1 : 0.45)
            }
            .padding(.top, 4)
        } label: {
            Text("フランジャー").font(.system(size: 12, weight: .semibold)).foregroundStyle(on ? Color.primary : Color.secondary)
        }
    }

    @ViewBuilder private func phaserGroup(_ c: Clip) -> some View {
        let d = fx?.phaser
        let on = d?.isActive ?? false
        DisclosureGroup(isExpanded: expanded("phaser", active: on)) {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("フェイザーを使う", isOn: onOff(d?.enabled ?? false, undo: "フェイザーの切り替え") {
                    _ = AudioFxEditing.setPhaserEnabled(&$0, $1)
                }).toggleStyle(.checkbox)
                let k = d ?? AudioFx.Phaser()
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(AudioFxEditing.PhaserParam.allCases, id: \.self) { p in
                        fxSlider(p.label, value: p.value(of: k), range: p.range, step: 0.05,
                                 format: { p == .rate ? String(format: "%.2f Hz", $0) : Self.pct($0) }, undo: p.undoName) {
                            _ = AudioFxEditing.setPhaser(&$0, p, $1)
                        }
                    }
                }.opacity((d?.enabled ?? false) ? 1 : 0.45)
            }
            .padding(.top, 4)
        } label: {
            Text("フェイザー").font(.system(size: 12, weight: .semibold)).foregroundStyle(on ? Color.primary : Color.secondary)
        }
    }

    @ViewBuilder private func tremoloGroup(_ c: Clip) -> some View {
        let d = fx?.tremolo
        let on = d?.isActive ?? false
        DisclosureGroup(isExpanded: expanded("tremolo", active: on)) {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("トレモロを使う", isOn: onOff(d?.enabled ?? false, undo: "トレモロの切り替え") {
                    _ = AudioFxEditing.setTremoloEnabled(&$0, $1)
                }).toggleStyle(.checkbox)
                let k = d ?? AudioFx.Tremolo()
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(AudioFxEditing.TremoloParam.allCases, id: \.self) { p in
                        fxSlider(p.label, value: p.value(of: k), range: p.range, step: 0.1,
                                 format: { p == .rate ? String(format: "%.1f Hz", $0) : Self.pct($0) }, undo: p.undoName) {
                            _ = AudioFxEditing.setTremolo(&$0, p, $1)
                        }
                    }
                }.opacity((d?.enabled ?? false) ? 1 : 0.45)
            }
            .padding(.top, 4)
        } label: {
            Text("トレモロ").font(.system(size: 12, weight: .semibold)).foregroundStyle(on ? Color.primary : Color.secondary)
        }
    }

    @ViewBuilder private func vibratoGroup(_ c: Clip) -> some View {
        let d = fx?.vibrato
        let on = d?.isActive ?? false
        DisclosureGroup(isExpanded: expanded("vibrato", active: on)) {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("ビブラートを使う", isOn: onOff(d?.enabled ?? false, undo: "ビブラートの切り替え") {
                    _ = AudioFxEditing.setVibratoEnabled(&$0, $1)
                }).toggleStyle(.checkbox)
                let k = d ?? AudioFx.Vibrato()
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(AudioFxEditing.VibratoParam.allCases, id: \.self) { p in
                        fxSlider(p.label, value: p.value(of: k), range: p.range, step: 0.1,
                                 format: { p == .rate ? String(format: "%.1f Hz", $0) : String(format: "%.1f ms", $0) }, undo: p.undoName) {
                            _ = AudioFxEditing.setVibrato(&$0, p, $1)
                        }
                    }
                }.opacity((d?.enabled ?? false) ? 1 : 0.45)
            }
            .padding(.top, 4)
        } label: {
            Text("ビブラート").font(.system(size: 12, weight: .semibold)).foregroundStyle(on ? Color.primary : Color.secondary)
        }
    }

    // MARK: ワウ

    @ViewBuilder private func wahGroup(_ c: Clip) -> some View {
        let d = fx?.wah
        let on = d?.isActive ?? false
        DisclosureGroup(isExpanded: expanded("wah", active: on)) {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("ワウを使う", isOn: onOff(d?.enabled ?? false, undo: "ワウの切り替え") {
                    _ = AudioFxEditing.setWahEnabled(&$0, $1)
                }).toggleStyle(.checkbox)
                let k = d ?? AudioFx.Wah()
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("オートワウ（音量で開く）", isOn: onOff(k.auto, undo: "オートワウの切り替え") {
                        _ = AudioFxEditing.setWahAuto(&$0, $1)
                    }).toggleStyle(.checkbox)
                    fxSlider("開き具合", value: k.positionValue, range: AudioFx.Wah.positionRange, step: 0.01, format: Self.pct, undo: AudioFxEditing.WahParam.position.undoName) {
                        _ = AudioFxEditing.setWah(&$0, .position, $1)
                    }
                    .opacity(k.auto ? 0.45 : 1)
                    fxSlider("感度", value: k.sensitivityValue, range: AudioFx.Wah.sensitivityRange, step: 0.01, format: Self.pct, undo: AudioFxEditing.WahParam.sensitivity.undoName) {
                        _ = AudioFxEditing.setWah(&$0, .sensitivity, $1)
                    }
                    .opacity(k.auto ? 1 : 0.45)
                }.opacity((d?.enabled ?? false) ? 1 : 0.45)
            }
            .padding(.top, 4)
        } label: {
            Text("ワウ / オートワウ").font(.system(size: 12, weight: .semibold)).foregroundStyle(on ? Color.primary : Color.secondary)
        }
    }

    // MARK: エコー

    @ViewBuilder private func echoGroup(_ c: Clip) -> some View {
        let d = fx?.echo
        let on = d?.isActive ?? false
        DisclosureGroup(isExpanded: expanded("echo", active: on)) {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("エコーを使う", isOn: onOff(d?.enabled ?? false, undo: "エコーの切り替え") {
                    _ = AudioFxEditing.setEchoEnabled(&$0, $1)
                }).toggleStyle(.checkbox)
                let k = d ?? AudioFx.Echo()
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(AudioFxEditing.EchoParam.allCases, id: \.self) { p in
                        fxSlider(p.label, value: p.value(of: k), range: p.range, step: p == .time ? 0.01 : 0.05,
                                 format: { p == .time ? String(format: "%.2f 秒", $0) : Self.pct($0) }, undo: p.undoName) {
                            _ = AudioFxEditing.setEcho(&$0, p, $1)
                        }
                    }
                    Text("ディレイより柔らかく、繰り返すたびに高域が落ちます。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.opacity((d?.enabled ?? false) ? 1 : 0.45)
            }
            .padding(.top, 4)
        } label: {
            Text("エコー").font(.system(size: 12, weight: .semibold)).foregroundStyle(on ? Color.primary : Color.secondary)
        }
    }

    // MARK: 低音質化 / ロボット化

    @ViewBuilder private func lowQualityGroup(_ c: Clip) -> some View {
        let d = fx?.lowQuality
        let on = d?.isActive ?? false
        DisclosureGroup(isExpanded: expanded("lowq", active: on)) {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("低音質化を使う", isOn: onOff(d?.enabled ?? false, undo: "低音質化の切り替え") {
                    _ = AudioFxEditing.setLowQualityEnabled(&$0, $1)
                }).toggleStyle(.checkbox)
                let k = d ?? AudioFx.LowQuality()
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(AudioFxEditing.LowQualityParam.allCases, id: \.self) { p in
                        fxSlider(p.label, value: p.value(of: k), range: p.range, step: 1,
                                 format: { p == .bits ? "\(Int($0.rounded())) bit" : "÷\(Int($0.rounded()))" }, undo: p.undoName) {
                            _ = AudioFxEditing.setLowQuality(&$0, p, $1)
                        }
                    }
                }.opacity((d?.enabled ?? false) ? 1 : 0.45)
            }
            .padding(.top, 4)
        } label: {
            Text("低音質化").font(.system(size: 12, weight: .semibold)).foregroundStyle(on ? Color.primary : Color.secondary)
        }
    }

    @ViewBuilder private func robotGroup(_ c: Clip) -> some View {
        let d = fx?.robot
        let on = d?.isActive ?? false
        DisclosureGroup(isExpanded: expanded("robot", active: on)) {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("ロボット化を使う", isOn: onOff(d?.enabled ?? false, undo: "ロボット化の切り替え") {
                    _ = AudioFxEditing.setRobotEnabled(&$0, $1)
                }).toggleStyle(.checkbox)
                let k = d ?? AudioFx.Robot()
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(AudioFxEditing.RobotParam.allCases, id: \.self) { p in
                        fxSlider(p.label, value: p.value(of: k), range: p.range, step: p == .frequency ? 1 : 0.01,
                                 format: { p == .frequency ? "\(Int($0.rounded())) Hz" : Self.pct($0) }, undo: p.undoName) {
                            _ = AudioFxEditing.setRobot(&$0, p, $1)
                        }
                    }
                    Text("リング変調による近似です。声が金属的になります。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.opacity((d?.enabled ?? false) ? 1 : 0.45)
            }
            .padding(.top, 4)
        } label: {
            Text("ロボット化").font(.system(size: 12, weight: .semibold)).foregroundStyle(on ? Color.primary : Color.secondary)
        }
    }
}
