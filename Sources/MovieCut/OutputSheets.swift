import SwiftUI
import MovieCutCore

// MARK: - 共有の部品(解像度の入力欄・FPS の入力欄)

/// 幅 × 高さ・縦横入れ替え・縦横比の固定・定番サイズ・今の状態の 1 行。「解像度を入力」シートと動画設定シートで共用する。
struct ResolutionFields: View {
    @Binding var input: ResolutionInput

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("幅")
                TextField("幅", text: Binding(get: { input.widthText }, set: { input.setWidth($0) }))
                    .textFieldStyle(.roundedBorder).frame(width: 84).multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("resolution-width")
                Text("×")
                Text("高さ")
                TextField("高さ", text: Binding(get: { input.heightText }, set: { input.setHeight($0) }))
                    .textFieldStyle(.roundedBorder).frame(width: 84).multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("resolution-height")
                Button { input.swap() } label: { Label("縦横を入れ替え", systemImage: "arrow.left.arrow.right") }
                    .help("幅と高さを入れ替えます")
                Spacer(minLength: 0)
            }
            Toggle("縦横比を固定", isOn: Binding(get: { input.lockAspect }, set: { input.setLock($0) }))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 6)], alignment: .leading, spacing: 6) {
                ForEach(Array(ResolutionInput.quickSizes.enumerated()), id: \.offset) { _, q in
                    Button(q.label) { input.set(width: q.width, height: q.height) }
                        .controlSize(.small)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(input.summary).font(.callout).monospacedDigit()
                if let err = input.validation {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
                ForEach(input.notices, id: \.self) { n in
                    Text(n).font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }
}

/// FPS の入力欄(数字・小数・分数)と定番ボタンと「1フレーム = … ms」の行。
struct FrameRateFields: View {
    @Binding var text: String

    private var result: Result<Double, InputError> { FrameRateInput.parse(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("フレームレート")
                TextField("例 29.97 / 12.5 / 30000/1001", text: $text)
                    .textFieldStyle(.roundedBorder).frame(width: 190).multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("fps-field")
                Text("fps")
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 6)], alignment: .leading, spacing: 6) {
                ForEach(FrameRate.presets, id: \.self) { v in
                    Button(FrameRate.label(v)) { text = FrameRate.label(v) }.controlSize(.small)
                }
            }
            HStack(spacing: 6) {
                Text("放送用").font(.caption).foregroundStyle(.secondary)
                ForEach(FrameRate.broadcastPresets, id: \.self) { v in
                    Button(FrameRate.label(v)) { text = FrameRate.label(v) }.controlSize(.small)
                }
            }
            switch result {
            case .success(let v): Text(FrameRateInput.describe(v)).font(.callout).monospacedDigit()
            case .failure(let e): Text(e.message).font(.caption).foregroundStyle(.red)
            }
        }
    }
}

// MARK: - 解像度を入力

/// 出力 ▸ 解像度 ▸ カスタム…。Return で適用、Esc で取り消し。
struct ResolutionSheet: View {
    @ObservedObject var model: ProjectModel
    @State private var input: ResolutionInput

    init(model: ProjectModel) {
        self.model = model
        _input = State(initialValue: ResolutionInput(width: model.project.width, height: model.project.height, codec: model.project.codec, fps: model.project.fps))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("解像度を入力").font(.title3.bold())
            ResolutionFields(input: $input)
            HStack {
                Spacer()
                Button("キャンセル") { model.showResolutionSheet = false }.keyboardShortcut(.cancelAction)
                Button("適用") { apply() }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(!input.isValid)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func apply() {
        guard let w = input.width, let h = input.height, input.isValid else { return }
        model.applyCustomResolution(width: w, height: h)
        model.showResolutionSheet = false
    }
}

// MARK: - フレームレートを入力

/// 出力 ▸ FPS ▸ カスタム…。
struct FrameRateSheet: View {
    @ObservedObject var model: ProjectModel
    @State private var text: String

    init(model: ProjectModel) {
        self.model = model
        _text = State(initialValue: FrameRate.label(model.project.fps))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("フレームレートを入力").font(.title3.bold())
            FrameRateFields(text: $text)
            HStack {
                Spacer()
                Button("キャンセル") { model.showFpsSheet = false }.keyboardShortcut(.cancelAction)
                Button("適用") { apply() }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled({ if case .failure = FrameRateInput.parse(text) { return true } else { return false } }())
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func apply() {
        guard case .success(let v) = FrameRateInput.parse(text) else { return }
        model.applyCustomFps(v)
        model.showFpsSheet = false
    }
}

// MARK: - 無音をカット…

/// 「クリップ ▸ 無音をカット…」。選んだクリップの音を一度測り、しきい値などを動かすと「N 箇所をカットします」がすぐ変わる。
/// 「カット」で全体が 1 回の Undo。Esc で取り消し。
struct SilenceCutSheet: View {
    @ObservedObject var model: ProjectModel
    @State private var profile: LevelProfile?
    @State private var loading = true
    @State private var failed = false
    @State private var threshold = SilenceParams.default.thresholdDb
    @State private var minSilence = SilenceParams.default.minSilence
    @State private var pad = SilenceParams.default.pad
    @State private var ripple = true

    private var params: SilenceParams { SilenceParams(thresholdDb: threshold, minSilence: minSilence, pad: pad).clamped }
    private var clipId: String? { model.silenceClipId }

    private var cuts: [SilenceRange] { profile?.silentRanges(params) ?? [] }
    private var removed: Double { cuts.reduce(0) { $0 + $1.length } }
    /// 全部が無音になるときは切れない。
    private var allSilent: Bool {
        guard let p = profile, !cuts.isEmpty else { return false }
        return SilenceDetector.keepRanges(silent: cuts, duration: p.duration).allSatisfy { $0.length < ClipEditing.minDuration }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("無音をカット").font(.headline)
            slider("しきい値", value: $threshold, range: SilenceParams.thresholdRange, step: 1, format: { String(format: "%.0f dB", $0) })
            slider("最短の無音", value: $minSilence, range: SilenceParams.minSilenceRange, step: 0.05, format: { String(format: "%.2f 秒", $0) })
            slider("余白", value: $pad, range: SilenceParams.padRange, step: 0.01, format: { String(format: "%.2f 秒", $0) })
            Toggle("後ろを詰める", isOn: $ripple).toggleStyle(.checkbox)
            Group {
                if loading {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("音を調べています…") }
                } else if failed {
                    Text("このクリップの音を読めませんでした。").foregroundStyle(.red)
                } else if allSilent {
                    Text("全体が無音になるので、カットできません。しきい値を下げてください。").foregroundStyle(.orange)
                } else {
                    Text("\(cuts.count) 箇所をカットします" + (cuts.isEmpty ? "" : String(format: "（合計 %.2f 秒）", removed)))
                }
            }
            .font(.callout)
            HStack {
                Spacer()
                Button("キャンセル") { model.showSilenceSheet = false }
                    .keyboardShortcut(.cancelAction)
                Button("カット") { commit() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(loading || failed || cuts.isEmpty || allSilent)
            }
        }
        .padding(20)
        .frame(width: 400)
        .task { await analyze() }
    }

    private func slider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, format: (Double) -> String) -> some View {
        HStack {
            Text(label).frame(width: 84, alignment: .leading)
            Slider(value: value, in: range, step: step)
            Text(format(value.wrappedValue)).monospacedDigit().frame(width: 64, alignment: .trailing)
        }
    }

    private func analyze() async {
        guard let id = clipId, let c = model.clip(id) else { loading = false; failed = true; return }
        let result = await Task.detached(priority: .userInitiated) { SilenceDetector.analyze(clip: c) }.value
        profile = result
        failed = result == nil
        loading = false
    }

    private func commit() {
        guard let id = clipId, let p = profile else { return }
        if model.cutSilence(clipId: id, profile: p, params: params, ripple: ripple) { model.showSilenceSheet = false }
    }
}
