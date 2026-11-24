import SwiftUI
import MovieCutCore

/// AIでラフカットを作る(第 1 版): タイムラインの素材の文字起こしを AI に読ませ、
/// 指示(自由文)と目標の尺に沿った保持区間のプランを作り、新しいシーンとして
/// 適用する(Undo 1 回)。元のタイムラインは変えない。
/// 接続は AIテキスト生成の設定を共有し、未設定のときは生成できない旨と導線を出す。
struct AIRoughCutSheet: View {
    @ObservedObject var model: ProjectModel
    @Environment(\.dismiss) private var dismiss
    @State private var instruction = ""
    @State private var useTarget = false
    @State private var targetSeconds = 180
    @State private var sources: [RoughCutSourceClip] = []
    @State private var plan: RoughCutPlan?
    @State private var generating = false

    private var configured: Bool { model.roughCutConfigured }
    private var canGenerate: Bool {
        configured && !sources.isEmpty && !generating
            && (!instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || useTarget)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t("AIでラフカットを作る")).font(.headline)
            if !configured {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.t("AIテキスト生成が設定されていません。接続先のエンドポイントとモデルを設定するまで、この機能は使えません。"))
                        .foregroundStyle(.orange)
                    Button(L10n.t("AIテキスト生成の設定…")) { TextGenerationDialogs.editSettings() }
                }
                .font(MCDesign.Font.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            }
            if sources.isEmpty {
                InspectorGuideCard(symbol: "text.badge.plus", heading: "対象の素材がありません",
                                   message: "文字起こしのある映像・音声クリップがタイムラインにありません。先に「音声から字幕を作る」などで素材の文字起こしを作ってください。")
            } else {
                Text(String(format: L10n.t("対象: クリップ %d 件(文字起こし %d 文)を AI に送ります"), sources.count, sources.reduce(0) { $0 + $1.segments.count }))
                    .font(MCDesign.Font.subheadline).foregroundStyle(MCDesign.Color.textSecondary)
            }
            HStack(spacing: 8) {
                Text(L10n.t("指示")).frame(width: 70, alignment: .trailing)
                TextField(L10n.t("例: つかみは一番面白いところから。間延びした部分は切って"), text: $instruction)
            }
            HStack(spacing: 8) {
                Text(L10n.t("目標の尺")).frame(width: 70, alignment: .trailing)
                Toggle(L10n.t("指定する"), isOn: $useTarget).labelsHidden()
                if useTarget {
                    LabeledStepperRow(label: ProjectModel.mediaTimeText(Double(targetSeconds)),
                                      onIncrement: { targetSeconds = StepperValue.stepped(targetSeconds, by: 10, in: 10...3600) },
                                      onDecrement: { targetSeconds = StepperValue.stepped(targetSeconds, by: -10, in: 10...3600) })
                } else {
                    Text(L10n.t("指定なし")).font(MCDesign.Font.subheadline).foregroundStyle(MCDesign.Color.textSecondary)
                }
                Spacer()
                if generating {
                    ProgressView().controlSize(.small)
                    Button(L10n.t("止める")) { model.cancelRoughCut() }
                } else {
                    Button(L10n.t("ラフカットを作る")) { Task { await generate() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canGenerate)
                }
            }
            if let plan {
                planView(plan)
            } else {
                Text(L10n.t("指示を入れて「ラフカットを作る」を押すと、設定した生成サービスに文字起こしと指示を送り、残す区間のプランを作ります。適用すると新しいシーンになり、元のタイムラインは変わりません。"))
                    .font(MCDesign.Font.subheadline).foregroundStyle(MCDesign.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            }
            HStack {
                Spacer()
                Button(L10n.t("キャンセル")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.t("シーンとして適用")) { apply() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(plan == nil || generating)
            }
        }
        .padding(16)
        .frame(width: 640)
        .onAppear { sources = model.roughCutSources() }
    }

    private func planView(_ plan: RoughCutPlan) -> some View {
        let labels = Dictionary(uniqueKeysWithValues: sources.map { ($0.clipId, $0.label) })
        return VStack(alignment: .leading, spacing: 6) {
            Text(String(format: L10n.t("プラン: 区間 %d 件・合計 %@"), plan.segments.count, ProjectModel.mediaTimeText(plan.totalDuration)))
                .font(MCDesign.Font.subheadline)
            if let summary = plan.summary {
                Text(summary).font(MCDesign.Font.subheadline).foregroundStyle(MCDesign.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if plan.droppedCount > 0 {
                Text(String(format: L10n.t("検証で %d 件の区間を落としました(範囲外・重なり・短すぎ)"), plan.droppedCount))
                    .font(MCDesign.Font.subheadline).foregroundStyle(.orange)
            }
            List {
                ForEach(Array(plan.segments.enumerated()), id: \.offset) { _, seg in
                    HStack(spacing: 8) {
                        Text(labels[seg.clipId] ?? seg.clipId).font(MCDesign.Font.subheadline).foregroundStyle(MCDesign.Color.textSecondary)
                            .frame(width: 140, alignment: .leading)
                        Text("\(ProjectModel.mediaTimeText(seg.start))–\(ProjectModel.mediaTimeText(seg.end))")
                            .font(MCDesign.Font.subheadline)
                        if let title = seg.title {
                            Text(title)
                        }
                    }
                }
            }
            .frame(minHeight: 160)
        }
    }

    private func generate() async {
        generating = true
        defer { generating = false }
        plan = await model.generateAIRoughCut(instruction: instruction,
                                              targetDuration: useTarget ? Double(targetSeconds) : nil,
                                              sources: sources)
    }

    private func apply() {
        guard let plan else { return }
        _ = model.applyAIRoughCut(plan)
        model.showAIRoughCutSheet = false
        dismiss()
    }
}
