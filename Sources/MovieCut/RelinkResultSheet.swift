import SwiftUI
import MovieCutCore

/// ファイル ▸ 素材の場所を再指定…の結果: つながった素材(旧 → 新)と、見つからなかった素材を分けて出す。
/// 同名でも中身が違うファイルは取り違えを防ぐためつながないので、その旨を添える。
struct RelinkResultSheet: View {
    @ObservedObject var model: ProjectModel
    let report: MediaRelinkReport

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.t("素材の場所の再指定")).font(.title3.bold())
            Text(String(format: L10n.t("つながった素材 %d 件・見つからなかった素材 %d 件"), report.relinked.count, report.unresolved.count))
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()

            Text(L10n.t("つながった素材")).font(.headline)
            if report.relinked.isEmpty {
                Text(L10n.t("つながった素材はありません。")).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                List(report.relinked) { link in
                    VStack(alignment: .leading, spacing: 2) {
                        Text((link.to as NSString).lastPathComponent).lineLimit(1)
                        Text(String(format: L10n.t("旧: %@"), link.from)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Text(String(format: L10n.t("新: %@"), link.to)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                .frame(minHeight: 120)
            }

            Text(L10n.t("見つからなかった素材")).font(.headline)
            Text(L10n.t("同じファイル名でも中身が違うファイルは、取り違えを防ぐため、つなぎません。見つからない素材は、正しいファイルがあるフォルダを選び直してください。"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if report.unresolved.isEmpty {
                Text(L10n.t("見つからなかった素材はありません。")).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                List(report.unresolved, id: \.self) { path in
                    VStack(alignment: .leading, spacing: 2) {
                        Text((path as NSString).lastPathComponent).lineLimit(1)
                        Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                .frame(minHeight: 120)
            }

            HStack {
                Spacer()
                Button(L10n.t("閉じる")) { model.relinkReport = nil }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 500)
    }
}
