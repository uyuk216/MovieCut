import SwiftUI
import MovieCutCore

/// 「字幕を追加…」のシート(複数行の文と長さ。既定 3 秒)。文字クリップを選んでいたときは、その文と長さを直す。
struct SubtitleQuickSheet: View {
    @ObservedObject var model: ProjectModel
    @State private var text = ""
    @State private var durationText = "3"
    @State private var failed = false

    private var editing: Bool { model.subtitleSheetTargetId != nil }
    private var canCommit: Bool { SubtitleQuickAdd.cleanedText(text) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(editing ? "字幕を編集" : "字幕を追加").font(.headline)
            Text(editing ? "選んでいる文字クリップの文と長さを直します。" : "再生位置から、字幕レイヤーに入れます。改行で複数行にできます。")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.body)
                .frame(width: 380, height: 110)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            HStack {
                Text("長さ")
                TextField("3", text: $durationText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                Text("秒").foregroundStyle(.secondary)
                if failed { Text("数字で入れてください").font(.caption).foregroundStyle(.red) }
            }
            if !canCommit {
                Text("文が空のときは追加できません").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("キャンセル") { model.showSubtitleSheet = false; model.subtitleSheetTargetId = nil }
                    .keyboardShortcut(.cancelAction)
                Button(editing ? "直す" : "追加") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCommit)
            }
        }
        .padding(16)
        .onAppear {
            if let id = model.subtitleSheetTargetId, let c = model.project.allClips.first(where: { $0.id == id }) {
                text = c.text ?? ""
                durationText = String(format: "%g", c.duration)
            }
        }
    }

    private func commit() {
        let normalized = durationText.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        guard let d = Double(normalized), d.isFinite else { failed = true; return }
        failed = false
        model.commitSubtitleSheet(text: text, duration: d)
    }
}
