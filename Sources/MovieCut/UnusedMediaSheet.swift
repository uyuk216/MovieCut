import SwiftUI
import MovieCutCore

/// ファイル ▸ 未使用の素材…: どのクリップにも使われていない素材の一覧。素材リストから外すだけで、ディスクのファイルは消さない。
struct UnusedMediaSheet: View {
    @ObservedObject var model: ProjectModel

    private var items: [UnusedMedia.Item] { UnusedMedia.find(in: model.project) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("未使用の素材").font(.title3.bold())
                Spacer()
                Text("\(items.count) 件").foregroundStyle(.secondary).monospacedDigit()
            }
            Text("どのクリップにも使われていない素材です。削除しても、ディスクのファイルは消えません(このプロジェクトの素材リストから外すだけです)。")
                .font(.caption).foregroundStyle(.secondary)
            if items.isEmpty {
                Text("未使用の素材はありません。").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 160)
            } else {
                List(items, id: \.path) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.fileName).lineLimit(1)
                            Text(item.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button("削除") { model.removeUnusedMedia([item.path]) }
                    }
                }
                .frame(minHeight: 240)
            }
            HStack {
                Button("一括削除") { model.removeUnusedMedia(nil) }.disabled(items.isEmpty)
                Spacer()
                Button("閉じる") { model.showUnusedMediaSheet = false }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 620)
    }
}
