import SwiftUI
import MovieCutCore

/// クリップ ▸ 話者分離…: 選んだクリップの音声を文字にし、区間ごとに話者ラベルを付ける。
/// 方式は音響特徴(声の高さ・音色の目安など)による簡易判定で、学習型の本格分離ではない。
/// ラベルは行ごとに手で直せて、字幕の新規作成・既存字幕への付与・台本欄への送信ができる。
/// 閉じると認識は止まる(`.task` のキャンセル)。
struct DiarizationSheet: View {
    @ObservedObject var model: ProjectModel
    @State private var run: DiarizationPipeline.Run?
    @State private var diarized: [DiarizedSegment] = []
    @State private var failure: String?
    @State private var maxSpeakers = 4
    @State private var useWhisper = false
    @State private var note: String?

    private var clipStart: Double { model.diarizationClipId.flatMap { model.clip($0)?.start } ?? 0 }
    private var speakerChoices: [Int] {
        let used = diarized.map(\.speaker).max() ?? 0
        return Array(0...(used + 1))   // 末尾は「新しい話者」用
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("話者分離").font(.headline)
            Text(SpeakerDiarizationInfo.limitationNotice)
                .font(MCDesign.Font.subheadline).foregroundStyle(MCDesign.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Picker("認識", selection: $useWhisper) {
                    Text("音声認識").tag(false)
                    Text("Whisper").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                Stepper(value: $maxSpeakers, in: 1...8) { Text("話者は最大 \(maxSpeakers) 人") }
                    .font(MCDesign.Font.subheadline)
                Button("分け直す") { recluster() }
                    .disabled(run == nil)
                Spacer()
            }
            Group {
                if let r = run {
                    if r.segments.isEmpty {
                        InspectorGuideCard(symbol: "text.magnifyingglass", heading: "文は見つかりませんでした", message: "音声に話し声が含まれているか、クリップを確かめてください。")
                    } else {
                        Text("\(r.segments.count) 区間、\(SpeakerLabels.speakerCount(diarized)) 人の話者に分けました。ラベルは行ごとに直せます。")
                            .font(MCDesign.Font.subheadline).foregroundStyle(MCDesign.Color.textSecondary)
                        List {
                            ForEach(Array(diarized.enumerated()), id: \.offset) { i, d in
                                HStack(spacing: 8) {
                                    Text(Self.time(clipStart + d.segment.start))
                                        .font(MCDesign.Font.monospaced(11))
                                        .foregroundStyle(MCDesign.Color.textSecondary).frame(width: 44, alignment: .trailing)
                                    Picker("", selection: Binding(get: { d.speaker }, set: { v in relabel(i, to: v) })) {
                                        ForEach(speakerChoices, id: \.self) { s in
                                            Text(speakerChoices.last == s && !diarized.contains(where: { $0.speaker == s })
                                                 ? "新しい話者(\(SpeakerLabels.label(for: s)))"
                                                 : SpeakerLabels.label(for: s)).tag(s)
                                        }
                                    }
                                    .labelsHidden().frame(width: 130)
                                    Text(d.segment.text)
                                }
                            }
                        }
                        .frame(minHeight: 240)
                    }
                } else if let e = failure {
                    Text(e).foregroundStyle(.red)
                } else {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("音声を文字にして、話者を分けています…") }
                }
            }
            .font(.callout)
            if let note {
                Text(note).font(MCDesign.Font.subheadline).foregroundStyle(MCDesign.Color.textSecondary)
            }
            HStack {
                Spacer()
                Button("キャンセル") { model.showDiarizationSheet = false }.keyboardShortcut(.cancelAction)
                Button("台本欄へ送る") {
                    let n = model.sendDiarizationToScript(diarized)
                    note = n > 0 ? "台本欄へ \(n) 行を送りました(1 回で元に戻せます)" : "送れる行がありませんでした"
                }
                .disabled(diarized.isEmpty)
                Button("既存の字幕に付ける") {
                    let n = model.applyDiarizationLabelsToExistingSubtitles(diarized)
                    note = n > 0 ? "字幕 \(n) 件に話者ラベルを付けました(1 回で元に戻せます)" : "付けられる字幕がありませんでした"
                }
                .disabled(diarized.isEmpty)
                Button("字幕を作る") {
                    if model.applyDiarizationToSubtitles(diarized) { model.showDiarizationSheet = false }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(diarized.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 680)
        .task { await load() }
    }

    private func load() async {
        do {
            let r = try await model.runDiarization(transcriber: useWhisper ? WhisperTranscriber() : SpeechFrameworkTranscriber(),
                                                   maxSpeakers: maxSpeakers)
            run = r
            diarized = r.diarized
        } catch is CancellationError {
            // 閉じたときは何もしない
        } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// 特徴はそのままに、上限だけ変えて分け直す(再認識はしない)。
    private func recluster() {
        guard let r = run else { return }
        diarized = AcousticClusterDiarizer().diarize(segments: r.segments, features: r.features,
                                                     options: DiarizationOptions(maxSpeakers: maxSpeakers))
    }

    private func relabel(_ index: Int, to speaker: Int) {
        diarized = SpeakerLabels.compacted(SpeakerLabels.relabeled(diarized, at: index, toSpeaker: speaker))
    }

    private static func time(_ t: Double) -> String {
        let m = Int(t) / 60, s = t - Double(m * 60)
        return String(format: "%d:%04.1f", m, s)
    }
}
