import SwiftUI
import MovieCutCore

/// 出力 ▸ 素材の内容を検索…のシート(メディアインテリジェンス検索 第 1 段)。
/// 文字起こし済みの素材を「話している内容の文」で横断検索し、一致した文の開始位置へ案内する。
/// 文字起こしが無い素材は対象外として一覧に出す(勝手に文字起こしは始めない)。
struct MediaSearchSheet: View {
    @ObservedObject var model: ProjectModel
    @State private var query = ""
    @State private var index: MediaSearch.Index?

    private var hits: [MediaSearch.Hit] {
        guard let index else { return [] }
        return MediaSearch.search(query, in: index)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.t("素材の内容を検索")).font(MCDesign.Font.title3.bold())
            Text(L10n.t("文字起こし済みの素材を、話している内容の文で検索します。結果を選ぶと、その文の位置へ移動します。"))
                .font(MCDesign.Font.subheadline).foregroundStyle(MCDesign.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                TextField(L10n.t("話している内容で検索"), text: $query)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("media-search-query")
                Button(L10n.t("再読み込み")) { index = model.mediaSearchIndex() }
            }
            if let index {
                if !index.hasSearchableMedia {
                    InspectorGuideCard(symbol: "text.magnifyingglass",
                                       heading: "文字起こし済みの素材がありません",
                                       message: "音のあるクリップを選んで「音声から字幕を作る」などで文字起こしすると、その素材が検索できるようになります。")
                        .frame(maxWidth: 460)
                } else if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(hits.isEmpty ? L10n.t("一致する文はありません") : "\(hits.count) 件の文が一致")
                        .font(MCDesign.Font.subheadline)
                        .foregroundStyle(hits.isEmpty ? MCDesign.Color.textSecondary : .primary)
                }
                if index.hasSearchableMedia {
                    List {
                        ForEach(hits) { hit in hitRow(hit) }
                    }
                    .frame(minHeight: 160)
                    .accessibilityIdentifier("media-search-results")
                }
                if !index.untranscribed.isEmpty {
                    Text(L10n.t("検索の対象外(文字起こしがありません)"))
                        .font(MCDesign.Font.headline)
                    Text(index.untranscribed.map(\.name).joined(separator: "、"))
                        .font(MCDesign.Font.subheadline).foregroundStyle(MCDesign.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                Button(L10n.t("閉じる")) { model.showMediaSearchSheet = false }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 560)
        .task { index = model.mediaSearchIndex() }
    }

    private func hitRow(_ hit: MediaSearch.Hit) -> some View {
        let location = index.flatMap { _ in MediaSearch.timelineLocation(for: hit, in: model.project) }
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(hit.mediaName).font(MCDesign.Font.headline).lineLimit(1).truncationMode(.middle)
                    Text(ProjectModel.mediaTimeText(hit.start))
                        .font(MCDesign.Font.subheadline).foregroundStyle(MCDesign.Color.textSecondary)
                }
                Text(hit.text).lineLimit(2)
                if location == nil {
                    Text(L10n.t("タイムラインに無い素材か、使う範囲の外の文です"))
                        .font(MCDesign.Font.subheadline).foregroundStyle(MCDesign.Color.textSecondary)
                }
            }
            Spacer(minLength: 8)
            Button(L10n.t("その位置へ移動")) { model.jumpToMediaHit(hit) }
                .disabled(location == nil)
        }
        .accessibilityIdentifier("media-search-hit")
    }
}
