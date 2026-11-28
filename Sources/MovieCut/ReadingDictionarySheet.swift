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
    @State private var deleteExtras = false
    @State private var syncing = false
    @State private var syncResult = ""

    struct Row: Identifiable {
        let id = UUID()
        var word = ""
        var reading = ""
        var accent = ""
        var pos: ReadingPartOfSpeech?
        var priority = ""

        init() {}
        init(_ e: ReadingEntry) {
            word = e.word; reading = e.reading
            accent = e.accentType.map(String.init) ?? ""
            pos = e.partOfSpeech
            priority = e.priority.map(String.init) ?? ""
        }
        var entry: ReadingEntry {
            ReadingEntry(word: word.trimmingCharacters(in: .whitespaces), reading: reading.trimmingCharacters(in: .whitespaces),
                         accentType: Int(accent.trimmingCharacters(in: .whitespaces)).map { max(0, $0) },
                         partOfSpeech: pos,
                         priority: Int(priority.trimmingCharacters(in: .whitespaces)).map { min(10, max(0, $0)) })
        }
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
                            TextField("型", text: $row.accent).frame(width: 36).help("アクセント型(0=平板)。空なら 0 で登録")
                            Picker("", selection: $row.pos) {
                                Text("品詞").tag(ReadingPartOfSpeech?.none)
                                ForEach(ReadingPartOfSpeech.allCases, id: \.self) { Text($0.label).tag(ReadingPartOfSpeech?.some($0)) }
                            }.labelsHidden().frame(width: 84).help("品詞(エンジン反映用)。空なら固有名詞")
                            TextField("優", text: $row.priority).frame(width: 30).help("優先度 0〜10(エンジン反映用)。空なら 5")
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
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Text("VOICEVOX エンジンのユーザー辞書へ反映(表記ごとに追加・更新。エンジンが起動している必要があります)").font(MCDesign.Font.subheadline).foregroundStyle(MCDesign.Color.textSecondary)
                    HStack {
                        Toggle("辞書にない語もエンジンから削除する", isOn: $deleteExtras).toggleStyle(.checkbox)
                        Spacer()
                        Button(syncing ? "反映中…" : "エンジンへ反映") { syncToEngine() }.disabled(syncing || rows.isEmpty && !deleteExtras)
                    }
                    if !syncResult.isEmpty {
                        Text(syncResult).font(MCDesign.Font.subheadline).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
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
        .frame(width: 720, height: 600)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            rows = model.project.readingDictionary.map { Row($0) }
        }
        .disabled(model.isLocked)
    }

    private func importFromText() {
        let parsed = ReadingDictionary.parse(text: importText)
        guard !parsed.isEmpty else { return }
        // 既にある表記は取り込み側で置き換え、それ以外は後ろに足す
        var merged = rows.map(\.entry)
        for e in parsed {
            if let i = merged.firstIndex(where: { $0.word == e.word }) { merged[i] = e } else { merged.append(e) }
        }
        rows = ReadingDictionary.normalized(merged).map { Row($0) }
        importText = ""
    }

    private func save() {
        model.setReadingDictionary(rows.map(\.entry))
        dismiss()
    }

    /// 編集中の辞書をエンジンの user_dict へ反映する(画面なし・結果は下に表示)。保存はしない。
    private func syncToEngine() {
        let entries = ReadingDictionary.normalized(rows.map(\.entry))
        let client = VoicevoxClient(baseURL: model.project.voicevoxUrl)
        let del = deleteExtras
        syncing = true; syncResult = ""
        Task {
            do {
                let r = try await client.syncUserDict(entries: entries, deleteExtras: del)
                syncResult = r.summary
            } catch {
                syncResult = "反映できませんでした: \(error.localizedDescription)"
            }
            syncing = false
        }
    }
}
