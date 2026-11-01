import SwiftUI
import MovieCutCore

/// インスペクタ「音声」の続き: パン、イコライザー、コンプレッサー、リバーブ、ノーマライズ(折りたためる)。
/// スライダーのドラッグは `beginGesture` 〜 `commitGesture` で 1 回の Undo にまとまり、トグル・ピッカーは 1 操作 = 1 回。
struct AudioFxPanel: View {
    @ObservedObject var model: ProjectModel
    let clipId: String
    /// 起動時に開いておく節(撮影・試験用。ふだんは、効いている節だけ開く)
    var forceExpanded = false

    @State private var openEQ: Bool?
    @State private var openComp: Bool?
    @State private var openReverb: Bool?
    @State private var openNorm: Bool?
    @State private var openDuck: Bool?

    fileprivate var clip: Clip? { model.clip(clipId) }

    private static func db(_ v: Double) -> String { (v > 0 ? "+" : v < 0 ? "−" : "") + String(format: "%.1f dB", abs(v)) }
    private static func panText(_ v: Double) -> String {
        let p = Int((abs(v) * 100).rounded())
        return p == 0 ? "中央" : (v < 0 ? "左 \(p)%" : "右 \(p)%")
    }

    fileprivate func expanded(_ s: Binding<Bool?>, active: Bool) -> Binding<Bool> {
        Binding(get: { s.wrappedValue ?? (forceExpanded || active) }, set: { s.wrappedValue = $0 })
    }

    /// 数値スライダー(ドラッグ = 1 回の Undo)。
    private func fxSlider(_ label: String, value: Double, range: ClosedRange<Double>, step: Double, format: @escaping (Double) -> String,
                          undo: String, apply: @escaping (inout Clip, Double) -> Void) -> some View {
        LiveSlider(label: label, value: value, range: range, step: step, format: format,
                   begin: { model.beginGesture() },
                   change: { v in model.liveAudioFx({ apply(&$0, v) }, name: undo, clipId: clipId) },
                   end: { model.commitGesture(undo) })
    }

    var body: some View {
        if let c = clip, AudioFxEditing.supports(c) {
            VStack(alignment: .leading, spacing: 8) {
                fxSlider("パン", value: c.panOrDefault, range: -1...1, step: 0.01, format: Self.panText, undo: ProjectModel.panUndoName) {
                    _ = AudioFxEditing.setPan(&$0, $1)
                }
                fxSlider("ノイズ除去", value: c.audioFx?.denoiseStrength ?? 0, range: 0...1, step: 0.01,
                         format: { "\(Int(($0 * 100).rounded()))%" }, undo: ProjectModel.denoiseUndoName) {
                    _ = AudioFxEditing.setDenoise(&$0, $1)
                }
                eqGroup(c)
                compressorGroup(c)
                reverbGroup(c)
                normalizeGroup(c)
                duckGroup(c)
            }
            .controlSize(.small)
            .disabled(model.isLocked)
        }
    }

    // MARK: イコライザー

    @ViewBuilder private func eqGroup(_ c: Clip) -> some View {
        let eq = c.audioFx?.eq ?? AudioFx.EQ()
        DisclosureGroup(isExpanded: expanded($openEQ, active: eq.isActive)) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(AudioFxEditing.Band.allCases, id: \.self) { band in
                    fxSlider(band.label, value: band.value(of: eq), range: AudioFx.EQ.range, step: 0.5, format: Self.db, undo: ProjectModel.eqUndoName) {
                        _ = AudioFxEditing.setEQ(&$0, band: band, db: $1)
                    }
                }
                HStack {
                    Spacer()
                    Button("リセット") { model.setAudioFx({ _ = AudioFxEditing.resetEQ(&$0) }, name: "イコライザーのリセット", clipId: clipId) }
                        .disabled(!eq.isActive)
                }
            }
            .padding(.top, 4)
        } label: {
            Text("イコライザー").font(.system(size: 12, weight: .semibold)).foregroundStyle(eq.isActive ? Color.primary : Color.secondary)
        }
    }

    // MARK: コンプレッサー

    @ViewBuilder private func compressorGroup(_ c: Clip) -> some View {
        let comp = c.audioFx?.compressor
        let on = comp?.isActive ?? false
        DisclosureGroup(isExpanded: expanded($openComp, active: on)) {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("コンプレッサーを使う", isOn: Binding(get: { on }, set: { v in
                    model.setAudioFx({ _ = AudioFxEditing.setCompressorEnabled(&$0, v) }, name: "コンプレッサーの切り替え", clipId: clipId)
                }))
                .toggleStyle(.checkbox)
                let k = comp ?? AudioFx.Compressor()
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(AudioFxEditing.CompressorParam.allCases, id: \.self) { p in
                        fxSlider(p.label, value: p.value(of: k), range: p.range, step: p == .ratio || p == .attack || p == .release ? 1 : 0.5,
                                 format: { p == .ratio ? String(format: "%.0f : 1", $0) : (p == .attack || p == .release ? String(format: "%.0f ms", $0) : Self.db($0)) },
                                 undo: p.undoName) { _ = AudioFxEditing.setCompressor(&$0, p, $1) }
                    }
                }
                .opacity(on ? 1 : 0.45)
            }
            .padding(.top, 4)
        } label: {
            Text("コンプレッサー").font(.system(size: 12, weight: .semibold)).foregroundStyle(on ? Color.primary : Color.secondary)
        }
    }

    // MARK: リバーブ

    @ViewBuilder private func reverbGroup(_ c: Clip) -> some View {
        let rv = c.audioFx?.reverb
        let on = rv?.isActive ?? false
        DisclosureGroup(isExpanded: expanded($openReverb, active: on)) {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("リバーブを使う", isOn: Binding(get: { rv?.enabled ?? false }, set: { v in
                    model.setAudioFx({ _ = AudioFxEditing.setReverbEnabled(&$0, v) }, name: "リバーブの切り替え", clipId: clipId)
                }))
                .toggleStyle(.checkbox)
                let k = rv ?? AudioFx.Reverb()
                VStack(alignment: .leading, spacing: 6) {
                    fxSlider("ミックス", value: k.mix, range: 0...1, step: 0.01, format: { "\(Int(($0 * 100).rounded()))%" }, undo: ProjectModel.reverbUndoName) {
                        _ = AudioFxEditing.setReverbMix(&$0, $1)
                    }
                    InspectorField(label: "広さ") {
                        Picker("", selection: Binding(get: { k.sizeOrDefault }, set: { v in
                            model.setAudioFx({ _ = AudioFxEditing.setReverbSize(&$0, v) }, name: ProjectModel.reverbUndoName, clipId: clipId)
                        })) {
                            ForEach(AudioFx.ReverbSize.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                }
                .opacity(rv?.enabled ?? false ? 1 : 0.45)
            }
            .padding(.top, 4)
        } label: {
            Text("リバーブ").font(.system(size: 12, weight: .semibold)).foregroundStyle(on ? Color.primary : Color.secondary)
        }
    }

    // MARK: ノーマライズ

    @ViewBuilder private func normalizeGroup(_ c: Clip) -> some View {
        let nm = c.audioFx?.normalize
        let on = nm?.isActive ?? false
        DisclosureGroup(isExpanded: expanded($openNorm, active: on)) {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("ノーマライズを使う", isOn: Binding(get: { on }, set: { v in
                    model.setAudioFx({ _ = AudioFxEditing.setNormalizeEnabled(&$0, v) }, name: "ノーマライズの切り替え", clipId: clipId)
                }))
                .toggleStyle(.checkbox)
                let k = nm ?? AudioFx.Normalize()
                let mode = k.modeOrDefault
                VStack(alignment: .leading, spacing: 6) {
                    InspectorField(label: "方式") {
                        Picker("", selection: Binding(get: { mode }, set: { v in
                            model.setAudioFx({ _ = AudioFxEditing.setNormalizeMode(&$0, v) }, name: ProjectModel.normalizeUndoName, clipId: clipId)
                        })) {
                            ForEach(AudioFx.NormalizeMode.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    fxSlider(mode == .peak ? "目標ピーク（dBFS）" : "目標ラウドネス（LUFS）", value: k.targetDb, range: AudioFx.Normalize.range(for: mode), step: 0.5,
                             format: { String(format: "%.1f", $0) }, undo: ProjectModel.normalizeUndoName) { _ = AudioFxEditing.setNormalizeTarget(&$0, $1) }
                    Text("クリップ全体を一度測って、音量を合わせます。EQ・コンプレッサー・リバーブの後に測ります。")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .opacity(on ? 1 : 0.45)
            }
            .padding(.top, 4)
        } label: {
            Text("ノーマライズ").font(.system(size: 12, weight: .semibold)).foregroundStyle(on ? Color.primary : Color.secondary)
        }
    }
}

extension AudioFxPanel {
    // MARK: 自動ダッキング(BGM の音声クリップだけ)

    @ViewBuilder fileprivate func duckGroup(_ c: Clip) -> some View {
        if DuckEditing.supports(c) {
            let on = c.hasDuck
            let d = c.duck ?? Duck()
            DisclosureGroup(isExpanded: expanded($openDuck, active: on)) {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("声があるときに BGM を下げる", isOn: Binding(get: { on }, set: { v in
                        model.setDuck({ _ = DuckEditing.setEnabled(&$0, v) }, name: v ? "自動ダッキングをオン" : "自動ダッキングをオフ", clipId: clipId)
                    }))
                    .toggleStyle(.checkbox)
                    VStack(alignment: .leading, spacing: 6) {
                        duckSlider("下げる量", value: d.amountDb, range: Duck.amountRange, step: 0.5, format: { String(format: "%.1f dB", $0) }) { _ = DuckEditing.setAmount(&$0, $1) }
                        duckSlider("下がる速さ（アタック）", value: d.attackSeconds, range: Duck.attackRange, step: 0.01, format: { String(format: "%.2f 秒", $0) }) { _ = DuckEditing.setAttack(&$0, $1) }
                        duckSlider("戻る速さ（リリース）", value: d.releaseSeconds, range: Duck.releaseRange, step: 0.05, format: { String(format: "%.2f 秒", $0) }) { _ = DuckEditing.setRelease(&$0, $1) }
                        Text("ボイスのクリップがある間、この音を下げます。声の少し前から下げ始め、終わると元に戻ります。プレビューも書き出しも同じです。")
                            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .opacity(on ? 1 : 0.45)
                }
                .padding(.top, 4)
            } label: {
                Text("自動ダッキング").font(.system(size: 12, weight: .semibold)).foregroundStyle(on ? Color.primary : Color.secondary)
            }
        }
    }

    private func duckSlider(_ label: String, value: Double, range: ClosedRange<Double>, step: Double, format: @escaping (Double) -> String,
                            apply: @escaping (inout Clip, Double) -> Void) -> some View {
        LiveSlider(label: label, value: value, range: range, step: step, format: format,
                   begin: { model.beginGesture() },
                   change: { v in model.liveDuck({ apply(&$0, v) }, clipId: clipId) },
                   end: { model.commitGesture("自動ダッキングの変更") })
    }
}
