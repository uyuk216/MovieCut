import SwiftUI
import MovieCutCore

/// 出力 ▸ 注記一覧…: 注記のあるクリップを開始時刻順に出す。行を選ぶとそのクリップへ移る。テキスト・CSV で書き出せる。
struct NoteListSheet: View {
    @ObservedObject var model: ProjectModel
    @State private var selection: String?

    private var rows: [NoteListing.Entry] { NoteListing.entries(in: model.project) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("注記一覧").font(.title3.bold())
                Spacer()
                Text("\(rows.count) 件").foregroundStyle(.secondary).monospacedDigit()
            }
            if rows.isEmpty {
                Text("注記はありません。インスペクタの「注記」に書くと、ここに出ます。")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 160)
            } else {
                Table(rows, selection: $selection) {
                    TableColumn("開始") { Text(String(format: "%.3f", $0.start)).monospacedDigit() }.width(min: 60, ideal: 72)
                    TableColumn("レイヤー") { Text($0.trackName) }.width(min: 60, ideal: 90)
                    TableColumn("注記") { Text($0.note).lineLimit(2) }.width(min: 180, ideal: 320)
                }
                .frame(minHeight: 240)
                .onChange(of: selection) { _, id in
                    guard let id, let e = rows.first(where: { $0.clipId == id }) else { return }
                    model.focusClip(id: e.clipId, at: e.start)
                }
            }
            HStack {
                Text("行を選ぶとクリップへ移ります。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("テキストで書き出す…") { model.chooseAndExportNotes(csv: false) }.disabled(rows.isEmpty)
                Button("CSV を書き出す…") { model.chooseAndExportNotes(csv: true) }.disabled(rows.isEmpty)
                Button("閉じる") { model.showNoteListSheet = false }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 680)
    }
}
