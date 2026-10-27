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
