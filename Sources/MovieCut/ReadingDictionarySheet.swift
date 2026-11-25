import SwiftUI
import AppKit
import MovieCutCore

/// 「読み辞書を編集…」: セリフの表記 → 読み(かな)の対応を、行ごとに編集する画面。
/// 保存でプロジェクトへ 1 回の Undo で書き込む(`ProjectModel.setReadingDictionary`)。
/// 辞書は台本から声を作るときに読み上げ文へだけ適用され、字幕は元の表記のまま残る。
struct ReadingDictionarySheet: View {
    @ObservedObject var model: ProjectModel
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [Row] = []
    @State private var importText = ""
    @State private var loaded = false

    struct Row: Identifiable {
        let id = UUID()
        var word = ""
        var reading = ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("読み辞書").font(.headline)
            Text("台本から声を作るとき、表記を読み(かな)に置き換えて読み上げます。字幕は元の表記のままです。あとから辞書を変えても、作り済みの音声は変わりません。")
                .font(MCDesign.Font.subheadline).foregroundStyle(MCDesign.Color.textSecondary).fixedSize(horizontal: false, vertical: true)
            if rows.isEmpty {
                InspectorGuideCard(symbol: "book.closed", heading: "辞書に登録された語はありません", message: "「行を追加」か、下のテキスト取り込みで読みを登録します。")
                    .frame(minHeight: 160)
            } else {
                List {
                    ForEach($rows) { $row in
                        HStack(spacing: 8) {
                            TextField("表記(例: 相棒)", text: $row.word).frame(width: 150)
                            Text("→").foregroundStyle(MCDesign.Color.textSecondary)
                            TextField("読み(例: あいぼう)", text: $row.reading)
                            Button {
                                rows.removeAll { $0.id == row.id }
                            } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .help("この行を消す")
                        }
                    }
                }
                .frame(minHeight: 160)
            }
            HStack(spacing: 8) {
                Button("行を追加") { rows.append(Row()) }
                Spacer()
                Text("\(rows.filter { !$0.word.isEmpty && !$0.reading.isEmpty }.count) 件")
                    .font(MCDesign.Font.subheadline).foregroundStyle(MCDesign.Color.textSecondary)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Text("テキストから取り込む(1 行 1 件:「表記,読み」「表記=読み」)").font(MCDesign.Font.subheadline).foregroundStyle(MCDesign.Color.textSecondary)
                    PlainTextEditor(text: $importText, font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)).frame(height: 54)
                    HStack {
                        Spacer()
                        Button("取り込む") { importFromText() }.disabled(importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { save() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 480, height: 520)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            rows = model.project.readingDictionary.map { Row(word: $0.word, reading: $0.reading) }
        }
        .disabled(model.isLocked)
    }

    private func importFromText() {
        let parsed = ReadingDictionary.parse(text: importText)
        guard !parsed.isEmpty else { return }
        // 既にある表記は取り込み側で置き換え、それ以外は後ろに足す
        var merged = rows.map { ReadingEntry(word: $0.word, reading: $0.reading) }
        for e in parsed {
            if let i = merged.firstIndex(where: { $0.word == e.word }) { merged[i] = e } else { merged.append(e) }
        }
        rows = ReadingDictionary.normalized(merged).map { Row(word: $0.word, reading: $0.reading) }
        importText = ""
    }

    private func save() {
        let entries = rows.map {
            ReadingEntry(word: $0.word.trimmingCharacters(in: .whitespaces),
                         reading: $0.reading.trimmingCharacters(in: .whitespaces))
        }
        model.setReadingDictionary(entries)
        dismiss()
    }
}
