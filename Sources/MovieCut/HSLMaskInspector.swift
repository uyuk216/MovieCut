import SwiftUI
import MovieCutCore

/// HSL マスク(Premiere 27.0「HSL マスキング」のローカル等価)のプロパティ欄。
/// 色相・彩度・輝度の範囲で領域を切り分けるマスク。範囲の指定は HSL セカンダリと
/// 同じ項目立て(中心・幅・ぼかし / 下限・上限・ぼかし)。値の編集は形のマスクと
/// 同じ作法(ドラッグは 1 回の Undo)。マスクプレビューで選択範囲を確認できる。
struct HSLMaskSection: View {
    @ObservedObject var model: ProjectModel
    let clip: Clip

    private static let pct: (Double) -> String = { "\(Int(($0 * 100).rounded()))%" }
    private static let deg: (Double) -> String = { "\(Int($0.rounded()))°" }
    private static let num2: (Double) -> String = { String(format: "%.2f", $0) }

    var body: some View {
        if Clip.supportsEffects(clip.type) {
            VStack(alignment: .leading, spacing: 6) {
                InspectorSection(title: L10n.t("HSLマスク"))
                Toggle(L10n.t("色の範囲で切り抜く（外は透明）"), isOn: Binding(get: { clip.hslMask != nil }, set: { on in
                    model.setHSLMask(on ? HSLMask() : nil, clipId: clip.id)
                }))
                .toggleStyle(.checkbox)
                if let m = clip.hslMask {
                    Text(L10n.t("色相・彩度・輝度で選んだ範囲だけが残ります。形のマスク・オブジェクトマスクと併用でき、両方あるときは両方かかります。"))
                        .font(MCDesign.Font.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    slider(L10n.t("色相の中心（°）"), m.selection.hueCenter, range: 0...360, step: 1, format: Self.deg) { m, v in m.selection.hueCenter = v }
                    slider(L10n.t("色相の幅（°）"), m.selection.hueWidth, range: 0...360, step: 1, format: Self.deg) { m, v in m.selection.hueWidth = v }
                    slider(L10n.t("色相のぼかし（°）"), m.selection.hueFeather, range: 0...180, step: 1, format: Self.deg) { m, v in m.selection.hueFeather = v }
                    slider(L10n.t("彩度の下限"), m.selection.satMin, range: 0...1, step: 0.01, format: Self.num2) { m, v in m.selection.satMin = v }
                    slider(L10n.t("彩度の上限"), m.selection.satMax, range: 0...1, step: 0.01, format: Self.num2) { m, v in m.selection.satMax = v }
                    slider(L10n.t("彩度のぼかし"), m.selection.satFeather, range: 0...0.5, step: 0.01, format: Self.num2) { m, v in m.selection.satFeather = v }
                    slider(L10n.t("輝度の下限"), m.selection.lumMin, range: 0...1, step: 0.01, format: Self.num2) { m, v in m.selection.lumMin = v }
                    slider(L10n.t("輝度の上限"), m.selection.lumMax, range: 0...1, step: 0.01, format: Self.num2) { m, v in m.selection.lumMax = v }
                    slider(L10n.t("輝度のぼかし"), m.selection.lumFeather, range: 0...0.5, step: 0.01, format: Self.num2) { m, v in m.selection.lumFeather = v }
                    Toggle(L10n.t("反転（中を透明にする）"), isOn: Binding(get: { m.invert }, set: { on in
                        model.setHSLMaskField(clipId: clip.id) { $0.invert = on }
                    }))
                    .toggleStyle(.checkbox)
                    Picker(L10n.t("マスクプレビュー"), selection: Binding(get: { m.preview }, set: { p in
                        model.setHSLMaskField(clipId: clip.id) { $0.preview = p }
                    })) {
                        Text(L10n.t("オフ")).tag(HSLMaskPreview.off)
                        Text(L10n.t("外をグレーで表示")).tag(HSLMaskPreview.grayOutside)
                        Text(L10n.t("中を色付きで表示")).tag(HSLMaskPreview.tintInside)
                    }
                    .pickerStyle(.segmented)
                    if m.preview != .off {
                        Text(L10n.t("プレビューは書き出しにも効きます。確認が終わったらオフに戻してください。"))
                            .font(MCDesign.Font.subheadline).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .disabled(model.isLocked)
        }
    }

    /// 範囲選択のスライダー(ドラッグは 1 回の Undo)。
    private func slider(_ label: String, _ value: Double, range: ClosedRange<Double>, step: Double,
                        format: @escaping (Double) -> String,
                        _ change: @escaping (inout HSLMask, Double) -> Void) -> some View {
        LiveSlider(label: label, value: value, range: range, step: step, format: format,
                   begin: { model.beginGesture() },
                   change: { v in model.liveHSLMaskField(clipId: clip.id) { change(&$0, v) } },
                   end: { model.commitGesture(ProjectModel.hslMaskUndoName) })
    }
}
