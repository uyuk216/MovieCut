import SwiftUI
import MovieCutCore

/// クリップ ▸ 選択クリップを音階で複製…
struct ScaleDuplicateSheet: View {
    @ObservedObject var model: ProjectModel
    @State private var scale: PitchScale = .major
    @State private var rootShift = 0
    @State private var count = 8
    @State private var descending = false

    private var clip: Clip? { model.scaleClipId.flatMap { model.clip($0) } }
    private var plan: (steps: [PitchStep], truncated: Int)? {
        clip.map { PitchLayout.scalePlan(clip: $0, scale: scale, rootShift: rootShift, count: count, descending: descending) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("音階で複製").font(.headline)
            Text("選んだクリップを、音階に沿って音程を変えながら、すき間なく並べます。元のクリップが 1 つ目の音になります。")
                .font(.callout).foregroundStyle(.secondary)
            Picker("音階", selection: $scale) {
                ForEach(PitchScale.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Stepper(value: $rootShift, in: -24...24) { Text("開始の音: 元の音から \(Self.semitoneText(rootShift))") }
            Stepper(value: $count, in: 1...PitchLayout.maxCount) { Text("個数: \(count)") }
            Toggle("下降する", isOn: $descending).toggleStyle(.checkbox)
            Group {
                if let plan {
                    if plan.steps.isEmpty {
                        Text("音程が ±24 半音の範囲を超えるため、作れません。").foregroundStyle(.orange)
                    } else {
                        Text("\(plan.steps.count) 個を並べます" + (plan.truncated > 0 ? "（音程の範囲を超える \(plan.truncated) 個は作りません）" : ""))
                    }
                }
            }.font(.callout)
            HStack {
                Spacer()
                Button("キャンセル") { model.showScaleSheet = false }.keyboardShortcut(.cancelAction)
                Button("複製") { commit() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(plan?.steps.isEmpty ?? true)
            }
        }
        .padding(20).frame(width: 420)
    }

    static func semitoneText(_ v: Int) -> String { v == 0 ? "0 半音" : (v > 0 ? "+" : "−") + "\(abs(v)) 半音" }

    private func commit() {
        guard let id = model.scaleClipId else { return }
        if model.applyScaleDuplicate(clipId: id, scale: scale, rootShift: rootShift, count: count, descending: descending) { model.showScaleSheet = false }
    }
}

/// クリップ ▸ ビートに合わせてクリップを並べる…
struct BeatPlaceSheet: View {
    @ObservedObject var model: ProjectModel
    @State private var beatsOnly = false
    @State private var pitchStep = 0
    @State private var limit = 0

    private var clip: Clip? { model.beatPlaceClipId.flatMap { model.clip($0) } }
    private var plan: (steps: [PitchStep], truncated: Int)? {
        guard let c = clip else { return nil }
        let times = PitchLayout.markerTimes(in: model.project, from: c.start, beatsOnly: beatsOnly)
        return PitchLayout.beatPlan(clip: c, times: times, pitchStep: Double(pitchStep), limit: limit)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ビートに合わせて並べる").font(.headline)
            Text("クリップの位置以降のマーカーの位置に、選んだクリップを繰り返し置きます。次のマーカーまでより長いぶんは短くなります。元のクリップが 1 つ目になります。")
                .font(.callout).foregroundStyle(.secondary)
            Toggle("「ビート」のマーカーだけを使う", isOn: $beatsOnly).toggleStyle(.checkbox)
            Stepper(value: $pitchStep, in: -12...12) { Text("1 つごとの音程の変化: \(ScaleDuplicateSheet.semitoneText(pitchStep))") }
            Stepper(value: $limit, in: 0...PitchLayout.maxCount) { Text("個数の上限: " + (limit == 0 ? "なし（すべて）" : "\(limit)")) }
            Group {
                if let plan {
                    if plan.steps.isEmpty {
                        Text("置ける位置がありません。").foregroundStyle(.orange)
                    } else {
                        Text("\(plan.steps.count) 個を並べます" + (plan.truncated > 0 ? "（音程の範囲を超える \(plan.truncated) 個は作りません）" : ""))
                    }
                }
            }.font(.callout)
            HStack {
                Spacer()
                Button("キャンセル") { model.showBeatPlaceSheet = false }.keyboardShortcut(.cancelAction)
                Button("並べる") { commit() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(plan?.steps.isEmpty ?? true)
            }
        }
        .padding(20).frame(width: 440)
    }

    private func commit() {
        guard let id = model.beatPlaceClipId else { return }
        if model.applyBeatPlace(clipId: id, beatsOnly: beatsOnly, pitchStep: Double(pitchStep), limit: limit) { model.showBeatPlaceSheet = false }
    }
}
