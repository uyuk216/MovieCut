import SwiftUI
import MovieCutCore

/// エッセンシャルサウンド: 音のあるクリップに種別(会話 / ミュージック / 効果音 / アンビエンス)を付け、
/// 種別ごとの整音プリセットをワンクリックで適用するパネル(インスペクタ「音声」の先頭に出る)。
/// 種別の変更(タグだけ)と整音の適用は別の操作で、どちらも Undo 1 回で戻せる。
/// 整音は既存のエフェクト設定の組み合わせなので、適用後も各エフェクトを個別に調整できる。
struct EssentialSoundPanel: View {
    @ObservedObject var model: ProjectModel
    let clipId: String

    private var clip: Clip? { model.clip(clipId) }

    var body: some View {
        if let c = clip, EssentialSoundEditing.supports(c) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.t("エッセンシャルサウンド"))
                    .font(MCDesign.Font.calloutSemibold)
                InspectorField(label: L10n.t("音の種類")) {
                    Picker("", selection: Binding(
                        get: { c.audioCategory },
                        set: { model.setAudioCategory(clipId: clipId, $0) }
                    )) {
                        Text(L10n.t("未分類")).tag(AudioCategory?.none)
                        ForEach(AudioCategory.allCases, id: \.self) { category in
                            Text(L10n.t(category.label)).tag(AudioCategory?.some(category))
                        }
                    }
                    .labelsHidden()
                }
                if let category = c.audioCategory {
                    Text(L10n.t(category.presetSummary))
                        .font(MCDesign.Font.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer()
                        Button(L10n.t("整音を適用")) { model.applyEssentialSound(clipId: clipId) }
                            .disabled(EssentialSoundEditing.isPresetApplied(c))
                    }
                } else {
                    Text(L10n.t("種類を選ぶと、その種類向けの整音をまとめて適用できます。適用後も各エフェクトは個別に調整できます。"))
                        .font(MCDesign.Font.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.bottom, 4)
        }
    }
}
