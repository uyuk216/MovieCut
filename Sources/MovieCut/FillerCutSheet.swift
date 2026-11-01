import SwiftUI
import MovieCutCore

/// クリップ ▸ フィラー語をカット…: 音声を文字にして見つかった語を一覧し、チェックしたものをカットする。
/// 閉じると認識は止まる(`.task` のキャンセル)。
struct FillerCutSheet: View {
    @ObservedObject var model: ProjectModel
    @State private var found: [FillerRange]?
    @State private var picked: Set<Int> = []
    @State private var failure: String?
    @State private var ripple = true

    private var clipId: String? { model.fillerClipId }
    private var clipStart: Double { clipId.flatMap { model.clip($0)?.start } ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("フィラー語をカット").font(.headline)
            Group {
                if let f = found {
                    if f.isEmpty {
                        Text("フィラー語は見つかりませんでした。")
                    } else {
                        Text("\(f.count) 件見つかりました。カットするものにチェックを入れてください。")
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(f.enumerated()), id: \.offset) { i, r in
                                    Toggle(isOn: Binding(get: { picked.contains(i) }, set: { on in
                                        if on { picked.insert(i) } else { picked.remove(i) }
                                    })) {
                                        Text("「\(r.text)」  \(String(format: "%.2f", clipStart + r.start)) 秒から \(String(format: "%.2f", r.end - r.start)) 秒")
                                            .monospacedDigit()
                                    }
                                    .toggleStyle(.checkbox)
                                }
                            }
                        }
                        .frame(maxHeight: 220)
                    }
                } else if let e = failure {
                    Text(e).foregroundStyle(.red)
                } else {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("音声を文字にしています…") }
                }
            }
            .font(.callout)
            Toggle("後ろを詰める", isOn: $ripple).toggleStyle(.checkbox)
            Text("「あの」「その」は普通の言葉としても使うので、チェックを確かめてからカットしてください。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("キャンセル") { model.showFillerSheet = false }
                    .keyboardShortcut(.cancelAction)
                Button("カット") { commit() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(found == nil || picked.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
        .task { await scan() }
    }

    private func scan() async {
        do {
            let r = try await model.scanFillers()
            found = r
            picked = Set(r.indices)
        } catch is CancellationError {
            // 閉じたときは何もしない
        } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func commit() {
        guard let id = clipId, let f = found else { return }
        let chosen = picked.sorted().map { f[$0] }
        if model.cutFillers(clipId: id, ranges: chosen, ripple: ripple) { model.showFillerSheet = false }
    }
}
