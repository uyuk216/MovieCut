import SwiftUI
import MovieCutCore

/// ノード式グレーディングの欄(エフェクト欄の下)。ノード一覧(追加・削除・並べ替え・有効切替・選択)と、
/// 選択中ノードのパラメータ編集(既存の色補正と同じスライダー・LUT 選択)。上のノードから順に評価される。
struct GradeNodesSection: View {
    @ObservedObject var model: ProjectModel
    let clip: Clip
    @State private var selectedId: String?

    private static let addKinds: [EffectKind] = [.colorWheels, .lut, .whiteBalance, .colorCurves, .hslSecondary, .exposure, .contrast, .saturation]

    private var nodes: [GradeNode] { clip.gradeNodes ?? [] }
    private var selected: GradeNode? { nodes.first { $0.id == selectedId } ?? nil }

    var body: some View {
        if Clip.supportsEffects(clip.type) {
            VStack(alignment: .leading, spacing: 6) {
                InspectorSection(title: L10n.t("グレーディングノード"))
                if nodes.isEmpty {
                    Text(L10n.t("ノードはありません。上から順に評価され、各ノードは不透明度で元の絵と混ざります。"))
                        .font(MCDesign.Font.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(nodes.enumerated()), id: \.element.id) { i, n in row(i, n) }
                Menu {
                    ForEach(Self.addKinds, id: \.rawValue) { k in
                        Button(L10n.t(k.label)) { if let id = model.addGradeNode(k, clipId: clip.id) { selectedId = id } }
                    }
                } label: { Text(L10n.t("＋ ノードを追加")) }
                    .menuStyle(.button).fixedSize().controlSize(.small).disabled(model.isLocked)
                if let n = selected { editor(n) }
            }
        }
    }

    private func button(_ symbol: String, _ help: String, enabled: Bool = true, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).frame(width: 22, height: 22).contentShape(Rectangle()) }
            .buttonStyle(.plain).disabled(!enabled || model.isLocked).help(L10n.t(help)).accessibilityLabel(L10n.t(help))
    }

    private func row(_ i: Int, _ n: GradeNode) -> some View {
        HStack(spacing: 2) {
            Toggle("", isOn: Binding(get: { n.enabled }, set: { model.setGradeNodeEnabled($0, id: n.id, clipId: clip.id) }))
                .toggleStyle(.checkbox).labelsHidden().help(L10n.t("オン/オフ"))
            Button { selectedId = n.id } label: {
                Text("\(i + 1). \(n.name.isEmpty ? L10n.t("ノード") : n.name)")
                    .font(MCDesign.Font.calloutSemibold).lineLimit(1)
                    .foregroundStyle(n.enabled ? Color.primary : Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            button("chevron.up", "上へ（先に評価）", enabled: i > 0) { model.moveGradeNode(id: n.id, by: -1, clipId: clip.id) }
            button("chevron.down", "下へ（後に評価）", enabled: i < nodes.count - 1) { model.moveGradeNode(id: n.id, by: 1, clipId: clip.id) }
            button("xmark", "このノードを外す") { model.removeGradeNode(id: n.id, clipId: clip.id) }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(n.id == selectedId ? 0.14 : 0.06)))
    }

    @ViewBuilder private func editor(_ n: GradeNode) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            LiveSlider(label: L10n.t("ノードの不透明度"), value: n.clampedOpacity, range: 0...1, step: 0.01, format: { "\(Int(($0 * 100).rounded()))%" },
                       begin: { model.beginGesture() },
                       change: { model.liveGradeNodeOpacity($0, id: n.id, clipId: clip.id) },
                       end: { model.commitGesture("ノードの不透明度の変更") })
            ForEach(Array(n.effects.enumerated()), id: \.offset) { _, e in
                if let kind = e.known {
                    ForEach(kind.params, id: \.key) { s in
                        LiveSlider(label: s.label, value: e.value(s.key), range: s.range, step: s.step, format: { s.step >= 1 ? "\(Int($0.rounded()))" : String(format: "%.2f", $0) },
                                   begin: { model.beginGesture() },
                                   change: { model.liveGradeNodeParam(s.key, $0, id: n.id, clipId: clip.id) },
                                   end: { model.commitGesture("ノードの調整") })
                    }
                    if kind == .lut {
                        HStack(spacing: 6) {
                            Text((e.path ?? "").isEmpty ? L10n.t("ファイル未選択") : ((e.path ?? "") as NSString).lastPathComponent)
                                .font(MCDesign.Font.subheadline).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                            Spacer(minLength: 4)
                            Button(L10n.t("選ぶ…")) { model.chooseGradeNodeLUT(id: n.id, clipId: clip.id) }.controlSize(.small).disabled(model.isLocked)
                        }
                    }
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
    }
}
