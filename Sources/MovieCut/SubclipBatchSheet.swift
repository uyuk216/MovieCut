import SwiftUI
import MovieCutCore

/// クリップ ▸ 範囲を指定してサブクリップを一括作成…: 1 行に「素材 範囲, 範囲…」を書くと、再生位置から順に並べる。
struct SubclipBatchSheet: View {
    @ObservedObject var model: ProjectModel
    @State private var text = ""
    @State private var creating = false

    private var parsed: SubclipBatch.Parsed { model.parseSubclipText(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("サブクリップを一括作成").font(.title3.bold())
            Text("1 行に「素材 範囲」を書きます。例: intro.mov 0:05-0:12, 0:30-0:41。範囲だけの行は直前の素材の続き。# で始まる行は注釈。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(.system(size: 13, design: .monospaced))
                .frame(minHeight: 160)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.4)))
            summary
            HStack {
                Menu("素材を挿入") {
                    ForEach(model.subclipPoolItems, id: \.self) { p in
                        Button((p as NSString).lastPathComponent) { insert(p) }
                    }
                }
                .disabled(model.subclipPoolItems.isEmpty)
                .fixedSize()
                Spacer()
                Button("キャンセル") { model.showSubclipSheet = false }.keyboardShortcut(.cancelAction)
                Button("作成") {
                    creating = true
                    Task {
                        let n = await model.createSubclips(from: text)
                        creating = false
                        if n > 0 { model.showSubclipSheet = false }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(parsed.specs.isEmpty || creating)
            }
        }
        .padding(20)
        .frame(width: 600)
    }

    @ViewBuilder private var summary: some View {
        let p = parsed
        VStack(alignment: .leading, spacing: 2) {
            Text(p.specs.isEmpty ? "作成される範囲: なし" : "作成される範囲: \(p.specs.count) 件(合計 \(String(format: "%.1f", p.specs.reduce(0) { $0 + $1.length })) 秒)")
                .font(.caption)
            ForEach(Array(p.errors.prefix(4).enumerated()), id: \.offset) { _, e in
                Text("\(e.line) 行目: \(e.message)").font(.caption).foregroundStyle(.red)
            }
            if p.errors.count > 4 { Text("ほか \(p.errors.count - 4) 件").font(.caption).foregroundStyle(.red) }
        }
    }

    private func insert(_ path: String) {
        let name = (path as NSString).lastPathComponent
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        text += "\(name) 0:00-0:05\n"
    }
}
