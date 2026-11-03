import SwiftUI
import MovieCutCore

/// クリップ ▸ 候補クリップを比較して差し替え…: 候補を選ぶたびにタイムラインへ仮に反映して、プレビューで見比べる。
/// 「差し替える」で確定(1 回の Undo)、「キャンセル」で元に戻す。位置・エフェクト・長さなどの設定はそのまま。
struct CandidateSwapSheet: View {
    @ObservedObject var model: ProjectModel

    private var cands: [CandidateSwap.Candidate] { model.currentCandidates() }
    private var selected: String? { model.candidateSession?.selectedPath }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("候補クリップを比較して差し替え").font(.title3.bold())
                Spacer()
                Text("\(cands.count) 件").foregroundStyle(.secondary).monospacedDigit()
            }
            Text("候補を選ぶとタイムラインに仮に反映されます。再生位置のプレビューで見比べてください。").font(.caption).foregroundStyle(.secondary)
            List {
                row(title: "元の素材", subtitle: nil, symbol: "arrow.uturn.backward", isSelected: selected == nil) { Task { await model.previewCandidate(nil) } }
                ForEach(cands) { c in
                    row(title: c.name, subtitle: (c.path as NSString).deletingLastPathComponent, symbol: MediaThumbnail.symbol(for: c.kind), isSelected: selected == c.path) {
                        Task { await model.previewCandidate(c.path) }
                    }
                }
            }
            .frame(minHeight: 220, maxHeight: 380)
            HStack {
                Button("ファイルから候補を足す…") { model.chooseCandidateFiles() }
                Spacer()
                Button("キャンセル") { model.cancelCandidateSwap() }.keyboardShortcut(.cancelAction)
                Button("差し替える") { model.commitCandidateSwap() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected == nil)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    @ViewBuilder private func row(title: String, subtitle: String?, symbol: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 22).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).lineLimit(1)
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                }
                Spacer()
                if isSelected { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
