import SwiftUI
import MovieCutCore

/// クリップ ▸ 台本を編集…: 既存のボイスクリップをセリフ一覧で編集する画面(#41)。
/// キャラ・セリフ(読み上げ文)・字幕・表情を表形式に直し、保存でプロジェクトへ 1 回の Undo で書き込む
/// (`ProjectModel.commitScriptTable`)。音声そのものは変えない(作り直しは既存の「音声の作り直し」)。
struct ScriptTableSheet: View {
    @ObservedObject var model: ProjectModel
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [Row] = []
    @State private var loaded = false
    @State private var notice: String?

    struct Row: Identifiable {
        let clipId: String
        var characterId: String?
        var spoken: String
        var expression: String
        var subtitle: String
        var noSubtitle: Bool
        var start: Double
        var id: String { clipId }

        init(_ line: VoiceLine) {
            clipId = line.clipId
            characterId = line.characterId
            spoken = line.spoken
            expression = line.expression
            if let sub = line.subtitle {
                subtitle = sub
                noSubtitle = sub.isEmpty
            } else {
                subtitle = ""
                noSubtitle = false
            }
            start = line.start
        }

        var voiceLine: VoiceLine {
            VoiceLine(clipId: clipId, characterId: characterId, characterName: "",
                      spoken: spoken, expression: expression,
                      subtitle: noSubtitle ? "" : (subtitle.isEmpty ? nil : subtitle),
                      start: start, duration: 0)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t("台本を編集")).font(.headline)
            Text(L10n.t("ボイスクリップのセリフ一覧です。キャラ・セリフ・字幕・表情を直して「保存」でまとめて反映します(1 回の Undo)。セリフの文字を変えても音声は作り直されません。「音声の作り直し」で新しいセリフの声になります。"))
                .font(MCDesign.Font.subheadline).foregroundStyle(MCDesign.Color.textSecondary).fixedSize(horizontal: false, vertical: true)
            if rows.isEmpty {
                InspectorGuideCard(symbol: "waveform", heading: "ボイスクリップがありません", message: "台本から声を作ると、ここにセリフの一覧が出ます。")
                    .frame(minHeight: 160)
            } else {
                List {
                    ForEach($rows) { $row in
                        HStack(spacing: 8) {
                            Text(Self.time(row.start)).font(MCDesign.Font.monospaced(11))
                                .foregroundStyle(MCDesign.Color.textSecondary).frame(width: 44, alignment: .trailing)
                            Picker("", selection: $row.characterId) {
                                Text(L10n.t("キャラなし")).tag(String?.none)
                                ForEach(model.project.characters) { ch in
                                    Text(ch.name).tag(String?.some(ch.id))
                                }
                            }
                            .labelsHidden().frame(width: 110)
                            TextField(L10n.t("セリフ"), text: $row.spoken)
                            TextField(L10n.t("字幕(空 = セリフと同じ)"), text: $row.subtitle).frame(width: 170)
                                .disabled(row.noSubtitle)
                            Toggle(L10n.t("字幕なし"), isOn: $row.noSubtitle).toggleStyle(.checkbox)
                                .font(MCDesign.Font.subheadline).frame(width: 76)
                            TextField(L10n.t("表情"), text: $row.expression).frame(width: 76)
                        }
                    }
                }
                .frame(minHeight: 260)
            }
            if let n = notice { Text(L10n.t(n)).font(MCDesign.Font.subheadline).foregroundStyle(.red) }
            HStack {
                Text(String(format: L10n.t("%d 行"), rows.count)).font(MCDesign.Font.subheadline).foregroundStyle(MCDesign.Color.textSecondary)
                Button(L10n.t("AIでセリフ案…")) { model.openDialogueSuggestionsFromScriptTable() }
                Spacer()
                Button(L10n.t("キャンセル")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.t("保存")) { save() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(rows.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 860)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            rows = model.scriptTableLines().map(Row.init)
        }
    }

    private func save() {
        // セリフを空にした行は当てられない。開いたまま知らせる(ほかの行は反映済み)
        let empty = rows.filter { $0.spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        let applied = model.commitScriptTable(rows.map(\.voiceLine))
        if model.isLocked {
            notice = "ロック中のため保存できませんでした"; return
        }
        if empty > 0 {
            notice = "セリフが空の \(empty) 行は反映されませんでした(反映できた行: \(applied))。セリフを入れるか、キャンセルで閉じてください。"
            return
        }
        model.showScriptTableSheet = false
        dismiss()
    }

    private static func time(_ t: Double) -> String {
        let m = Int(t) / 60, s = t - Double(m * 60)
        return String(format: "%d:%04.1f", m, s)
    }
}
