import SwiftUI

/// ファイル ▸ 素材の場所を再指定…の結果: つながった素材(旧 → 新)と、見つからなかった素材を分けて出す。
/// 同名でも中身が違うファイルは取り違えを防ぐためつながないので、その旨を添える。
struct RelinkResultSheet: View {
    @ObservedObject var model: ProjectModel
    let report: MediaRelinkReport

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("素材の場所の再指定").font(.title3.bold())
            Text("つながった素材 \(report.relinked.count) 件・見つからなかった素材 \(report.unresolved.count) 件")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()

            Text("つながった素材").font(.headline)
            if report.relinked.isEmpty {
                Text("つながった素材はありません。").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                List(report.relinked) { link in
                    VStack(alignment: .leading, spacing: 2) {
                        Text((link.to as NSString).lastPathComponent).lineLimit(1)
                        Text("旧: \(link.from)").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Text("新: \(link.to)").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                .frame(minHeight: 120)
            }

            Text("見つからなかった素材").font(.headline)
            Text("同じファイル名でも中身が違うファイルは、取り違えを防ぐため、つなぎません。見つからない素材は、正しいファイルがあるフォルダを選び直してください。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if report.unresolved.isEmpty {
                Text("見つからなかった素材はありません。").foregroundStyle(.secondary)
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
                Button("閉じる") { model.relinkReport = nil }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 500)
    }
}
