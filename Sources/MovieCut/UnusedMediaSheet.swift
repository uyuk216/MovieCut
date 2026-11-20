import SwiftUI
import MovieCutCore

/// ファイル ▸ 未使用の素材…: どのクリップにも使われていない素材の一覧。素材リストから外すだけで、ディスクのファイルは消さない。
struct UnusedMediaSheet: View {
    @ObservedObject var model: ProjectModel

    private var items: [UnusedMedia.Item] { UnusedMedia.find(in: model.project) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.t("未使用の素材")).font(.title3.bold())
                Spacer()
                Text(String(format: L10n.t("%d 件"), items.count)).foregroundStyle(.secondary).monospacedDigit()
            }
            Text(L10n.t("どのクリップにも使われていない素材です。削除しても、ディスクのファイルは消えません(このプロジェクトの素材リストから外すだけです)。"))
                .font(.caption).foregroundStyle(.secondary)
            if items.isEmpty {
                InspectorGuideCard(symbol: "checkmark.circle", heading: "未使用の素材はありません", message: "すべての素材がクリップで使われています。")
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                List(items, id: \.path) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.fileName).lineLimit(1)
                            Text(item.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button(L10n.t("削除")) { model.removeUnusedMedia([item.path]) }
                    }
                }
                .frame(minHeight: 240)
            }
            HStack {
                Button(L10n.t("一括削除")) { model.removeUnusedMedia(nil) }.disabled(items.isEmpty)
                Spacer()
                Button(L10n.t("閉じる")) { model.showUnusedMediaSheet = false }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 620)
    }
}
