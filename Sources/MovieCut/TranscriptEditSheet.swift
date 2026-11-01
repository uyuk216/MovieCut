import SwiftUI
import MovieCutCore

/// クリップ ▸ 文字起こしで編集…: 音声を文字にして文の一覧を出す。チェックを外した文を取り除く(全部チェック = 何も変えない)。
/// 閉じると認識は止まる(`.task` のキャンセル)。
struct TranscriptEditSheet: View {
    @ObservedObject var model: ProjectModel
    @State private var found: [TranscriptSentence]?
    @State private var kept: Set<Int> = []
    @State private var failure: String?
    @State private var ripple = true

    private var clipId: String? { model.transcriptEditClipId }
    private var clipStart: Double { clipId.flatMap { model.clip($0)?.start } ?? 0 }
    private var removedCount: Int { (found?.count ?? 0) - kept.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("文字起こしで編集").font(.headline)
            Group {
                if let f = found {
                    if f.isEmpty {
                        Text("文は見つかりませんでした。")
                    } else {
                        Text("\(f.count) 文あります。残す文にチェックを入れたまま、外した文は取り除かれます。")
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(f.enumerated()), id: \.offset) { i, s in
                                    Toggle(isOn: Binding(get: { kept.contains(i) }, set: { on in
                                        if on { kept.insert(i) } else { kept.remove(i) }
                                    })) {
                                        Text("\(String(format: "%.2f", clipStart + s.start)) 秒  \(s.text)")
                                            .monospacedDigit()
                                    }
                                    .toggleStyle(.checkbox)
                                }
                            }
                        }
                        .frame(maxHeight: 260)
                    }
                } else if let e = failure {
                    Text(e).foregroundStyle(.red)
                } else {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("音声を文字にしています…") }
                }
            }
            .font(.callout)
            Toggle("後ろを詰める", isOn: $ripple).toggleStyle(.checkbox)
            HStack {
                Spacer()
                Button("キャンセル") { model.showTranscriptEditSheet = false }
                    .keyboardShortcut(.cancelAction)
                Button(removedCount > 0 ? "\(removedCount) 文を取り除く" : "取り除く") { commit() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(found == nil || removedCount <= 0)
            }
        }
        .padding(20)
        .frame(width: 520)
        .task { await scan() }
    }

    private func scan() async {
        do {
            let r = try await model.scanTranscriptSentences()
            found = r
            kept = Set(r.indices)
        } catch is CancellationError {
            // 閉じたときは何もしない
        } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func commit() {
        guard let id = clipId, let f = found else { return }
        let removed = f.indices.filter { !kept.contains($0) }.map { f[$0] }
        if model.cutTranscriptSentences(clipId: id, removed: removed, ripple: ripple) { model.showTranscriptEditSheet = false }
    }
}
