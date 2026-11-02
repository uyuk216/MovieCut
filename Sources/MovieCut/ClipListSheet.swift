import SwiftUI
import MovieCutCore

/// 出力 ▸ 使用クリップ一覧…: 全レイヤーのクリップを開始時刻順の表で出す。行を選ぶとそのクリップへ移る。
/// TSV はクリップボードへ、CSV は保存パネルで書き出す(並びと列は `ClipListingExport` が決める)。
struct ClipListSheet: View {
    @ObservedObject var model: ProjectModel
    @State private var selection: String?

    private var rows: [TimelineQuery.ListEntry] { model.clipListEntries }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("使用クリップ一覧").font(.title3.bold())
                Spacer()
                Text("\(rows.count) 件").foregroundStyle(.secondary).monospacedDigit()
            }
            if rows.isEmpty {
                Text("クリップがありません").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                Table(rows, selection: $selection) {
                    TableColumn("レイヤー") { Text($0.trackName) }.width(min: 60, ideal: 90)
                    TableColumn("名前") { Text($0.label).lineLimit(1) }.width(min: 120, ideal: 200)
                    TableColumn("開始") { Text(Self.seconds($0.start)).monospacedDigit() }.width(min: 60, ideal: 72)
                    TableColumn("長さ") { Text(Self.seconds($0.duration)).monospacedDigit() }.width(min: 60, ideal: 72)
                    TableColumn("素材パス") { Text($0.source ?? "—").lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary) }
                        .width(min: 120, ideal: 220)
                }
                .frame(minHeight: 260)
                .onChange(of: selection) { _, id in
                    guard let id, let e = rows.first(where: { $0.clipId == id }) else { return }
                    model.focusClipFromList(e)
                }
            }
            HStack {
                Text("行を選ぶとクリップへ移ります。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("TSV をコピー") { model.copyClipListTSV() }
                    .disabled(rows.isEmpty)
                Button("CSV を書き出す…") { model.chooseAndExportClipListCSV() }
                    .disabled(rows.isEmpty)
                Button("閉じる") { model.showClipListSheet = false }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 720)
    }

    private static func seconds(_ v: Double) -> String { String(format: "%.3f", v) }
}
