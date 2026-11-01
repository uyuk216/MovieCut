import SwiftUI
import MovieCutCore

/// 編集 ▸ 検索と置換…のシート。テロップ(文字クリップ)とセリフ(ボイスクリップ)の文字を一括で置き換える。
/// 一致の数は入力のたびに数え直す(何も変えない)。「すべて置換」で全体を 1 回の Undo にまとめる。
struct FindReplaceSheet: View {
    @ObservedObject var model: ProjectModel
    @State private var query = ""
    @State private var replacement = ""
    @State private var caseSensitive = false
    @State private var selectionOnly = false
    @State private var working = false

    private var hasSelection: Bool { !model.selectedClipIDs.isEmpty }
    private var options: TextSearch.Options { TextSearch.Options(caseSensitive: caseSensitive) }
    private var count: Int { model.findTextMatchCount(query, selectionOnly: selectionOnly && hasSelection, options: options) }

    private var countText: String {
        if query.isEmpty { return "検索する文字を入れてください" }
        return count == 0 ? "一致 0 件" : "\(count) 件一致"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("検索と置換").font(.headline)
            Text("テロップ(文字クリップ)とセリフ(ボイス)の文字を対象にします。")
                .font(.callout).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("検索")
                    TextField("", text: $query).textFieldStyle(.roundedBorder).frame(width: 260)
                }
                GridRow {
                    Text("置換")
                    TextField("", text: $replacement).textFieldStyle(.roundedBorder).frame(width: 260)
                }
            }
            Toggle("大文字と小文字を区別する", isOn: $caseSensitive).toggleStyle(.checkbox)
            Toggle("選んでいるクリップだけ", isOn: $selectionOnly).toggleStyle(.checkbox).disabled(!hasSelection)
            Text(countText)
                .font(.callout)
                .foregroundStyle(count == 0 ? .secondary : .primary)
            Text("セリフの文字が変わると、音声を作り直します。すべて元に戻すのは 1 回です。")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("閉じる") { model.showFindSheet = false }
                    .keyboardShortcut(.cancelAction)
                Button("すべて置換") { replaceAll() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(count == 0 || working || model.isLocked)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func replaceAll() {
        working = true
        Task {
            let n = await model.replaceAllText(query, with: replacement, options: options, selectionOnly: selectionOnly && hasSelection)
            working = false
            if n > 0 { model.showFindSheet = false }
        }
    }
}
