import SwiftUI
import MovieCutCore

/// AIでセリフ案を作る(W3-08 / 監査 #74): テーマとキーワードからセリフ案を生成し、
/// チェックした案だけを台本欄へ取り込む(Undo 1 回)。台本欄・台本編集ウィンドウ・
/// クリップメニューから開く。
/// 未設定のときは生成できず、その旨と設定への導線を出す(機能は無効)。
struct DialogueSuggestionSheet: View {
    @ObservedObject var model: ProjectModel
    @Environment(\.dismiss) private var dismiss
    @State private var theme = ""
    @State private var keywordsText = ""
    @State private var count = 8
    @State private var suggestions: [DialogueSuggestion]?
    @State private var selected: Set<Int> = []
    @State private var generating = false

    private var configured: Bool { model.textGenerationConfigured }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t("AIでセリフ案を作る")).font(.headline)
            if !configured {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.t("AIテキスト生成が設定されていません。接続先のエンドポイントとモデルを設定するまで、この機能は使えません。"))
                        .foregroundStyle(.orange)
                    Button(L10n.t("AIテキスト生成の設定…")) { TextGenerationDialogs.editSettings() }
                }
                .font(MCDesign.Font.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Text(L10n.t("テーマ")).frame(width: 70, alignment: .trailing)
                TextField(L10n.t("例: 初めての猫カフェ"), text: $theme)
            }
            HStack(spacing: 8) {
                Text(L10n.t("キーワード")).frame(width: 70, alignment: .trailing)
                TextField(L10n.t("カンマ区切り(任意)"), text: $keywordsText)
            }
            HStack(spacing: 8) {
                Text(L10n.t("件数")).frame(width: 70, alignment: .trailing)
                Stepper(value: $count, in: DialogueSuggestionPrompt.countRange) { Text(String(format: L10n.t("%d 件"), count)) }
                Spacer()
                if generating {
                    ProgressView().controlSize(.small)
                    Button(L10n.t("止める")) { model.cancelTextGeneration() }
                } else {
                    Button(L10n.t("セリフ案を作る")) { Task { await generate() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(!configured || theme.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if let list = suggestions {
                if list.isEmpty {
                    InspectorGuideCard(symbol: "text.bubble", heading: "案はまだありません", message: "テーマを変えて「セリフ案を作る」を押してください。")
                } else {
                    Text(String(format: L10n.t("取り込む案にチェックを入れてください(%d 件選択中)"), selected.count))
                        .font(MCDesign.Font.subheadline).foregroundStyle(MCDesign.Color.textSecondary)
                    List {
                        ForEach(Array(list.enumerated()), id: \.offset) { i, s in
                            Toggle(isOn: Binding(get: { selected.contains(i) }, set: { on in
                                if on { selected.insert(i) } else { selected.remove(i) }
                            })) {
                                HStack(spacing: 8) {
                                    Text(s.characterName ?? "—").font(MCDesign.Font.subheadline).foregroundStyle(MCDesign.Color.textSecondary).frame(width: 80, alignment: .leading)
                                    Text(s.text)
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                    .frame(minHeight: 200)
                }
            } else {
                Text(L10n.t("テーマを入れて「セリフ案を作る」を押すと、設定した生成サービスに問い合わせて案を出します。今の台本の末尾も、続きの参考として一緒に送ります。"))
                    .font(MCDesign.Font.subheadline).foregroundStyle(MCDesign.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            }
            HStack {
                Spacer()
                Button(L10n.t("キャンセル")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.t("台本欄へ取り込む")) { importSelected() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 640)
    }

    private func generate() async {
        generating = true
        defer { generating = false }
        let keywords = keywordsText.split(whereSeparator: { $0 == "," || $0 == "、" })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let got = await model.generateDialogueSuggestions(theme: theme, keywords: keywords, count: count) {
            suggestions = got
            selected = Set(got.indices)
        }
    }

    private func importSelected() {
        guard let list = suggestions else { return }
        let chosen = list.enumerated().filter { selected.contains($0.offset) }.map(\.element)
        _ = model.importDialogueSuggestions(chosen)
        model.showDialogueSuggestionSheet = false
        dismiss()
    }
}
